"""phone-adb-run: the one program that talks to the user's phone over adb.

Runs as the `phone-adb` system user, which alone holds the adb key and the adb server (listening on a
private Unix socket in a directory only that user can enter). The primary user reaches it through one sudo rule,
so a process running as them -- Claude Code, say -- cannot use the key or the server directly.

Two tiers:
  free     connect / disconnect / pair / status / info / screenshot / notifications / apps / ls / pull
           (reading; `pull` and `ls` only under shared storage)
  granted  shell / push -- anything that changes or drives the phone. Needs a grant that only the
           polkit-authenticated phone-adb-grant (root) can write. The grant lasts for a session: it
           expires after an idle period or a maximum time, or when revoked. See phone_adb_grant.py.

Exit status: 0 ok, 1 error, 77 not authorised (no valid grant), 78 phone not connected.
"""
import ipaddress
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time

CONF = {
    "adb": "@adb@",
    "avahi": "@avahiBrowse@",
    "sock": "@sock@",
    "home": "@home@",
    "grant": "@grantFile@",
    "state": "@stateDir@",
    "grant_uid": 0,  # the grant file must belong to root; tests override
}
NOT_AUTHORISED, NOT_CONNECTED = 77, 78
PRIVATE = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")]
SHARED = re.compile(r"^/(sdcard|storage/emulated/0)(/[^\0\n']*)?$")
PUSHABLE = re.compile(r"^/(sdcard|storage/emulated/0|data/local/tmp)(/[^\0\n']*)?$")


def out(obj):
    print(json.dumps(obj, ensure_ascii=False))


def die(msg, code=1, **extra):
    out({"error": msg, **extra})
    sys.exit(code)


# --- calling adb -----------------------------------------------------------------------------------

def adb_env(c):
    return {"HOME": c["home"], "PATH": "/run/current-system/sw/bin", "LANG": "C.UTF-8",
            "ADB_SERVER_SOCKET": "localfilesystem:" + c["sock"]}


def adb(c, *args, serial=None, stdin=None, timeout=60, binary=False):
    cmd = [c["adb"]] + (["-s", serial] if serial else []) + list(args)
    try:
        return subprocess.run(cmd, env=adb_env(c), input=stdin, capture_output=True, timeout=timeout,
                              text=not binary)
    except subprocess.TimeoutExpired:
        die(f"adb {args[0]} timed out after {timeout}s")
    except OSError as e:
        die(f"cannot run adb: {e}")


def devices(c):
    r = adb(c, "devices", timeout=15)
    if r.returncode != 0:
        return None  # no server
    out_ = []
    for line in r.stdout.splitlines()[1:]:
        parts = line.split("\t")
        if len(parts) == 2:
            out_.append({"serial": parts[0], "state": parts[1]})
    return out_


def the_phone(c):
    """Serial of the connected phone, or exit 78."""
    ds = devices(c)
    live = [d["serial"] for d in (ds or []) if d["state"] == "device"]
    if not live:
        die("the phone is not connected: switch on Wireless debugging on it (the watcher connects "
            "by itself), or run `phone adb connect`", NOT_CONNECTED)
    return live[0]


def lan(addr):
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if ip.version == 6:
        return ip.is_private and not ip.is_link_local  # link-local needs a scope adb cannot take
    return any(ip in n for n in PRIVATE)


def discover(c):
    """The phone's wireless-debugging advertisement(s) on the local network, via Avahi."""
    try:
        r = subprocess.run([c["avahi"], "-rtp", "_adb-tls-connect._tcp"], capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return []
    found = []
    for line in r.stdout.splitlines():
        f = line.split(";")
        if f[0] == "=" and len(f) >= 9 and lan(f[7]):
            found.append({"name": f[3], "address": f[7], "port": int(f[8]), "ip": f[2]})
    return sorted(found, key=lambda x: x["ip"] != "IPv4")


def endpoint(f):
    return f"[{f['address']}]:{f['port']}" if ":" in f["address"] else f"{f['address']}:{f['port']}"


def connect_first(c, found):
    """Try each advertised device in turn: other phones on the network advertise too, and only the one
    paired with this account will answer. Returns (target, message) of the first that connects."""
    seen, last = set(), "no device advertised"
    for f in found:
        t = endpoint(f)
        if t in seen:
            continue
        seen.add(t)
        r = adb(c, "connect", t, timeout=20)
        msg = (r.stdout + r.stderr).strip()
        if "connected to" in msg and "failed" not in msg.lower():
            return t, msg
        last = msg
    return None, last


def target(s):
    m = re.fullmatch(r"(\[?[0-9a-fA-F:.]+\]?):(\d{1,5})", s or "")
    if not m or not lan(m.group(1).strip("[]")) or not (0 < int(m.group(2)) < 65536):
        die("target must be HOST:PORT with a local-network address")
    return s


# --- the grant (written only by phone-adb-grant, as root, after polkit) ---------------------------------

class Gate:
    def __init__(self, c):
        self.c = c

    def _grant(self):
        try:
            st = os.stat(self.c["grant"])
            if st.st_uid != self.c["grant_uid"] or st.st_mode & 0o022:
                return None  # not written by root, or writable by others: ignore
            with open(self.c["grant"]) as f:
                return json.load(f)
        except (OSError, ValueError):
            return None

    def _last_used(self, g):
        try:
            with open(os.path.join(self.c["state"], "last_used")) as f:
                return max(float(f.read().strip()), g["granted_at"])
        except (OSError, ValueError):
            return g["granted_at"]

    def info(self, uid, now=None):
        now = now or time.time()
        g = self._grant()
        if not g:
            return {"active": False, "reason": "no grant"}
        if g.get("uid") != uid:
            return {"active": False, "reason": "the grant is for another user"}
        if now >= g["max_until"]:
            return {"active": False, "reason": "the grant expired (maximum time)"}
        idle_left = self._last_used(g) + g["idle_s"] - now
        if idle_left <= 0:
            return {"active": False, "reason": "the grant expired (idle)"}
        return {"active": True, "idle_left_s": int(idle_left), "max_left_s": int(g["max_until"] - now)}

    def require(self, uid):
        i = self.info(uid)
        if not i["active"]:
            die(f"not authorised: {i['reason']}. Ask the user to run `phone adb authorize` (a polkit prompt)",
                NOT_AUTHORISED)
        os.makedirs(self.c["state"], exist_ok=True)
        tmp = os.path.join(self.c["state"], "last_used.tmp")
        with open(tmp, "w") as f:
            f.write(str(time.time()))
        os.replace(tmp, os.path.join(self.c["state"], "last_used"))


def caller_uid():
    try:
        return int(os.environ.get("SUDO_UID", ""))
    except ValueError:
        return -1


# --- free commands -----------------------------------------------------------------------------------

def cmd_status(c, a):
    ds = devices(c)
    out({"server": ds is not None, "devices": ds or [], "advertised": discover(c) if a.scan else None,
         "grant": Gate(c).info(caller_uid())})


def cmd_connect(c, a):
    if a.target:
        t = target(a.target)
        r = adb(c, "connect", t, timeout=30)
        msg = (r.stdout + r.stderr).strip()
        ok = "connected to" in msg and "failed" not in msg.lower()
        out({"connected": ok, "target": t, "message": msg})
        sys.exit(0 if ok else 1)
    found = discover(c)
    if not found:
        die("the phone is not advertising wireless debugging: switch it on in Developer options", NOT_CONNECTED)
    t, msg = connect_first(c, found)
    out({"connected": t is not None, "target": t, "message": msg, "tried": len({endpoint(f) for f in found})})
    sys.exit(0 if t else 1)


def cmd_disconnect(c, a):
    r = adb(c, "disconnect", timeout=15)
    out({"disconnected": True, "message": (r.stdout + r.stderr).strip()})


def cmd_pair(c, a):
    if not re.fullmatch(r"\d{6}", a.code):
        die("the pairing code is 6 digits")
    r = adb(c, "pair", target(a.target), a.code, timeout=45)
    msg = (r.stdout + r.stderr).strip()
    ok = "Successfully paired" in msg
    out({"paired": ok, "message": msg})
    sys.exit(0 if ok else 1)


def getprop(c, serial, name):
    return adb(c, "shell", "getprop", name, serial=serial, timeout=15).stdout.strip()


def cmd_info(c, a):
    s = the_phone(c)
    bat = adb(c, "shell", "dumpsys", "battery", serial=s, timeout=20).stdout
    field = lambda k: (re.search(rf"^\s*{k}:\s*(.+)$", bat, re.M) or [None, None])[1]  # noqa: E731
    out({"model": getprop(c, s, "ro.product.model"), "android": getprop(c, s, "ro.build.version.release"),
         "battery": {"level": field("level"), "powered_ac": field("AC powered"), "usb": field("USB powered"),
                     "status": field("status")}, "serial": s})


def cmd_screenshot(c, a):
    s = the_phone(c)
    r = adb(c, "exec-out", "screencap", "-p", serial=s, timeout=30, binary=True)
    if not r.stdout.startswith(b"\x89PNG"):
        die("the phone did not return an image (screen off or protected content)")
    sys.stdout.buffer.write(r.stdout)
    sys.stdout.buffer.flush()


def cmd_notifications(c, a):
    s = the_phone(c)
    txt = adb(c, "shell", "dumpsys", "notification", "--noredact", serial=s, timeout=30).stdout
    items = []
    for blk in txt.split("NotificationRecord(")[1:]:
        pkg = re.search(r"pkg=(\S+)", blk)
        title = re.search(r"android\.title=(?:\w+ \((.*?)\)$|(.*)$)", blk, re.M)
        body = re.search(r"android\.text=(?:\w+ \((.*?)\)$|(.*)$)", blk, re.M)
        pick = lambda m: (m.group(1) if m and m.group(1) is not None else (m.group(2) if m else None))  # noqa: E731
        if pkg:
            items.append({"package": pkg.group(1), "title": pick(title), "text": pick(body)})
    out({"notifications": items})


def cmd_apps(c, a):
    s = the_phone(c)
    r = adb(c, "shell", "pm", "list", "packages", "-3", serial=s, timeout=30)
    out({"apps": sorted(l.split(":", 1)[1] for l in r.stdout.splitlines() if l.startswith("package:"))})


def shared(p, pattern=SHARED):
    if not pattern.match(p or "") or ".." in p.split("/"):
        die("only paths under /sdcard (shared storage) are allowed here")
    return p


def cmd_ls(c, a):
    s = the_phone(c)
    r = adb(c, "exec-out", f"ls -la {shlex.quote(shared(a.path))}", serial=s, timeout=30)
    out({"path": a.path, "listing": r.stdout.splitlines()})


def cmd_pull(c, a):
    s = the_phone(c)
    r = adb(c, "exec-out", f"cat {shlex.quote(shared(a.path))}", serial=s, timeout=300, binary=True)
    if r.returncode != 0:
        die("could not read that file: " + r.stderr.decode("utf-8", "replace").strip())
    sys.stdout.buffer.write(r.stdout)
    sys.stdout.buffer.flush()


# --- granted commands -----------------------------------------------------------------------------------

def cmd_shell(c, a):
    Gate(c).require(caller_uid())
    s = the_phone(c)
    r = adb(c, "shell", " ".join(a.command), serial=s, timeout=a.timeout, binary=True)
    sys.stdout.buffer.write(r.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(r.stderr)
    sys.exit(r.returncode)


def cmd_push(c, a):
    Gate(c).require(caller_uid())
    s = the_phone(c)
    data = sys.stdin.buffer.read()
    r = adb(c, "shell", f"cat > {shlex.quote(shared(a.path, PUSHABLE))}", serial=s, stdin=data, timeout=300, binary=True)
    out({"pushed": r.returncode == 0, "bytes": len(data), "path": a.path})
    sys.exit(r.returncode)


# --- the watcher (a system service) ----------------------------------------------------------------------

def start_server(c):
    d = os.path.dirname(c["sock"])
    os.makedirs(d, mode=0o700, exist_ok=True)
    try:
        os.remove(c["sock"])
    except OSError:
        pass
    return subprocess.Popen([c["adb"], "-L", "localfilesystem:" + c["sock"], "server", "nodaemon"], env=adb_env(c),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cmd_watch(c, a, iterations=None):
    """Keep the adb server up and connect to the phone whenever it advertises wireless debugging."""
    server = None
    signal.signal(signal.SIGTERM, lambda *_: (server and server.terminate(), sys.exit(0)))
    n = 0
    while iterations is None or n < iterations:
        n += 1
        if server is None or server.poll() is not None:
            server = start_server(c)
            time.sleep(1.5)
        ds = devices(c) or []
        if not any(d["state"] == "device" for d in ds):
            for d in ds:
                adb(c, "disconnect", d["serial"], timeout=10)
            connect_first(c, discover(c))
        time.sleep(a.interval if a else 8)
    if server:
        server.terminate()


def build_parser():
    import argparse
    ap = argparse.ArgumentParser(prog="phone-adb")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("status")
    p.add_argument("--scan", action="store_true", help="also look for the phone's advertisement (a few seconds)")
    sub.add_parser("connect").add_argument("target", nargs="?")
    sub.add_parser("disconnect")
    p = sub.add_parser("pair")
    p.add_argument("target")
    p.add_argument("code")
    for n in ("info", "screenshot", "notifications", "apps"):
        sub.add_parser(n)
    for n in ("ls", "pull"):
        sub.add_parser(n).add_argument("path")
    p = sub.add_parser("shell")
    p.add_argument("--timeout", type=int, default=300)
    p.add_argument("command", nargs="+")
    sub.add_parser("push").add_argument("path")
    p = sub.add_parser("watch")
    p.add_argument("--interval", type=int, default=8)
    return ap


COMMANDS = {"status": cmd_status, "connect": cmd_connect, "disconnect": cmd_disconnect, "pair": cmd_pair,
            "info": cmd_info, "screenshot": cmd_screenshot, "notifications": cmd_notifications, "apps": cmd_apps,
            "ls": cmd_ls, "pull": cmd_pull, "shell": cmd_shell, "push": cmd_push, "watch": cmd_watch}


def main(argv=None, conf=None):
    a = build_parser().parse_args(argv)
    COMMANDS[a.cmd](conf or CONF, a)


if __name__ == "__main__":
    main()
