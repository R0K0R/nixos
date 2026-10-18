#!/usr/bin/env python3
"""gtconnect - a ProxyCommand that reaches its target through proxy hops.

ssh needs nothing from a hop but a byte stream to the next one. This builds
that stream through a run of SOCKS5 and/or HTTP CONNECT proxies, then shuttles
bytes between it and ssh on stdin/stdout:

  gtconnect.py [--via CMD] --proxy KIND HOST PORT USER PASSFILE ... --target HOST:PORT

KIND is socks5 or http. USER and PASSFILE are "-" when the proxy takes no
credentials; PASSFILE names a file holding the password -- never the password
itself, which would sit in ps output and in the generated ssh config.

--via is how to reach the FIRST proxy when it is not directly dialable: a
command whose stdin/stdout are a stream to it, typically
`ssh -F cfg -W proxy:port gt-hop-N` for a proxy only reachable from an ssh
jump. It is split with shlex and run without a shell, so the gateway user's
login shell cannot mangle it. Without --via the first proxy is dialed directly.

Stdlib only: this runs on the client, wherever globaltun itself runs.
"""
import base64
import ipaddress
import os
import select
import shlex
import socket
import struct
import subprocess
import sys

HANDSHAKE_TIMEOUT = 60

SOCKS5_ERRORS = {
    1: "general failure", 2: "connection not allowed by ruleset",
    3: "network unreachable", 4: "host unreachable", 5: "connection refused",
    6: "TTL expired", 7: "command not supported", 8: "address type not supported",
}


def die(msg):
    sys.stderr.write("gtconnect: %s\n" % msg)
    sys.exit(1)


class Stream:
    """Two fds: one to read from, one to write to. A socket uses the same fd
    for both; a --via subprocess uses its stdout and stdin."""

    def __init__(self, rfd, wfd, keep=None, proc=None):
        self.rfd, self.wfd, self.keep, self.proc = rfd, wfd, keep, proc

    def read(self, n):
        r, _, _ = select.select([self.rfd], [], [], HANDSHAKE_TIMEOUT)
        if not r:
            die("timed out waiting for a proxy to answer")
        return os.read(self.rfd, n)

    def readn(self, n):
        b = b""
        while len(b) < n:
            d = self.read(n - len(b))
            if not d:
                die("proxy closed the connection mid-handshake")
            b += d
        return b

    def write(self, data):
        while data:
            n = os.write(self.wfd, data)
            data = data[n:]

    def shutdown_write(self):
        # Half-close, so the far end sees EOF but its replies still arrive.
        if self.keep is not None:
            try:
                self.keep.shutdown(socket.SHUT_WR)
            except OSError:
                pass
        else:
            try:
                os.close(self.wfd)
            except OSError:
                pass


def dial(host, port):
    try:
        s = socket.create_connection((host, port), HANDSHAKE_TIMEOUT)
    except OSError as e:
        die("cannot reach %s:%d: %s" % (host, port, e.strerror or e))
    s.settimeout(None)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return Stream(s.fileno(), s.fileno(), keep=s)


def via(cmd):
    try:
        p = subprocess.Popen(shlex.split(cmd), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, bufsize=0)
    except OSError as e:
        die("cannot run --via %r: %s" % (cmd, e))
    return Stream(p.stdout.fileno(), p.stdin.fileno(), proc=p)


def password(passfile):
    if passfile == "-":
        return None
    try:
        with open(passfile, "rb") as f:
            return f.read().rstrip(b"\r\n")
    except OSError as e:
        die("cannot read password file %s: %s" % (passfile, e.strerror))


def socks5(st, label, host, port, user, pw):
    methods = b"\x00\x02" if user else b"\x00"
    st.write(b"\x05" + bytes([len(methods)]) + methods)
    ver, method = st.readn(2)
    if ver != 5:
        die("%s is not a SOCKS5 proxy" % label)
    if method == 2:
        if not user or pw is None:
            die("%s requires a username and password" % label)
        u = user.encode()
        st.write(b"\x01" + bytes([len(u)]) + u + bytes([len(pw)]) + pw)
        if st.readn(2)[1] != 0:
            die("%s rejected the username/password" % label)
    elif method == 0xFF:
        die("%s accepts none of our auth methods" % label)
    elif method != 0:
        die("%s chose unsupported auth method %d" % (label, method))

    # The target goes as a NAME unless it is an address literal: the next hop
    # may only resolve on the far side of this proxy -- socks5h semantics.
    try:
        ip = ipaddress.ip_address(host)
        addr = (b"\x01" if ip.version == 4 else b"\x04") + ip.packed
    except ValueError:
        h = host.encode()
        addr = b"\x03" + bytes([len(h)]) + h
    st.write(b"\x05\x01\x00" + addr + struct.pack("!H", port))

    _, rep, _, atyp = st.readn(4)
    if rep != 0:
        die("%s refused CONNECT to %s:%d: %s" %
            (label, host, port, SOCKS5_ERRORS.get(rep, "error %d" % rep)))
    # Drain the bound address; its length depends on its type.
    st.readn({1: 4, 4: 16}.get(atyp, 0) or st.readn(1)[0])
    st.readn(2)


def http_connect(st, label, host, port, user, pw):
    hp = "[%s]:%d" % (host, port) if ":" in host else "%s:%d" % (host, port)
    req = "CONNECT %s HTTP/1.1\r\nHost: %s\r\n" % (hp, hp)
    if user:
        if pw is None:
            die("%s: a username needs a password file" % label)
        cred = base64.b64encode(user.encode() + b":" + pw).decode()
        req += "Proxy-Authorization: Basic %s\r\n" % cred
    st.write((req + "\r\n").encode())

    # Byte at a time, deliberately: anything read past the blank line is the
    # first bytes of the tunnelled stream (the next sshd's banner), and
    # swallowing them here would corrupt the ssh handshake.
    head = b""
    while not head.endswith(b"\r\n\r\n"):
        c = st.readn(1)
        head += c
        if len(head) > 16384:
            die("%s sent an oversized response header" % label)
    status = head.split(b"\r\n", 1)[0].decode("latin-1")
    parts = status.split(" ", 2)
    if len(parts) < 2 or parts[1] != "200":
        die("%s refused CONNECT to %s: %s" % (label, hp, status))


def relay(st):
    """stdin -> stream, stream -> stdout, until the stream ends."""
    ins, outs = {0: st.wfd}, {st.rfd: 1}
    stdin_open = True
    while True:
        watch = [st.rfd] + ([0] if stdin_open else [])
        r, _, _ = select.select(watch, [], [])
        if 0 in r:
            d = os.read(0, 65536)
            if d:
                st.write(d)
            else:
                stdin_open = False
                st.shutdown_write()
        if st.rfd in r:
            d = os.read(st.rfd, 65536)
            if not d:
                return
            while d:
                n = os.write(1, d)
                d = d[n:]


def main(argv):
    via_cmd, target, proxies = None, None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--via":
            via_cmd = argv[i + 1]; i += 2
        elif a == "--target":
            target = argv[i + 1]; i += 2
        elif a == "--proxy":
            kind, host, port, user, passfile = argv[i + 1:i + 6]
            if kind not in ("socks5", "http"):
                die("unknown proxy kind %r" % kind)
            proxies.append((kind, host, int(port),
                            None if user == "-" else user, passfile))
            i += 6
        else:
            die("unknown argument %r" % a)
    if not proxies or not target:
        die("need at least one --proxy and a --target")
    th, _, tp = target.rpartition(":")
    th = th.strip("[]")

    first = proxies[0]
    st = via(via_cmd) if via_cmd else dial(first[1], first[2])

    # Each proxy is asked to CONNECT to the next one; the last, to the target.
    hops = proxies[1:] + [(None, th, int(tp), None, None)]
    for (kind, host, port, user, passfile), nxt in zip(proxies, hops):
        label = "%s proxy %s:%d" % (kind, host, port)
        pw = password(passfile)
        if kind == "socks5":
            socks5(st, label, nxt[1], nxt[2], user, pw)
        else:
            http_connect(st, label, nxt[1], nxt[2], user, pw)

    relay(st)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (BrokenPipeError, ConnectionResetError):
        pass
    except KeyboardInterrupt:
        pass
