#!/usr/bin/env python3
"""Turn a VPN's own config into a vpns.d/ snippet for render-profile.py.

  vpn2singbox.py wg CONF.conf  ROUTING [--tag T]    any wg-quick config: Mullvad,
                                                    Proton, Surfshark, IVPN,
                                                    Windscribe, AirVPN, PIA,
                                                    CyberGhost, TorGuard, hide.me,
                                                    Cloudflare WARP (via wgcf), a
                                                    home router, your own server
  vpn2singbox.py ss 'ss://...' ROUTING [--tag T]    Outline / Shadowsocks access key
  vpn2singbox.py nordvpn --token TOKEN [--country KR] ROUTING
                                                    NordLynx (WireGuard) via Nord's
                                                    API -- needs internet
  vpn2singbox.py warp ROUTING                       registers a free Cloudflare WARP
                                                    device (no wgcf needed) --
                                                    needs internet

ROUTING says which traffic goes to it -- at least one of:
  --final               the default exit: everything not matched elsewhere
                        (DNS follows it, so lookups do not leak around it)
  --apps PKG[,PKG]      only these Android apps (package names)
  --cidr NET[,NET]      only these destinations
  --domains SUF[,SUF]   only these domain suffixes

Writes the snippet to stdout, or to -o FILE (mode 600: it holds keys). Put it
in vpns.d/ beside globaltun-termux.sh and run `up` again.
"""
import argparse, base64, json, os, re, sys, urllib.parse, urllib.request


def die(msg):
    print(f"vpn2singbox: {msg}", file=sys.stderr)
    sys.exit(1)


def split_list(v):
    return [x.strip() for x in v.split(",") if x.strip()] if v else []


def host_port(s):
    """'host:port' or '[v6]:port'."""
    m = re.fullmatch(r"\[([^\]]+)\]:(\d+)|([^:]+):(\d+)", s.strip())
    if not m:
        die(f"cannot parse endpoint {s!r} (want host:port)")
    return (m.group(1) or m.group(3)), int(m.group(2) or m.group(4))


def routing(args, tag):
    rules = []
    if args.apps:
        rules.append({"package_name": split_list(args.apps), "outbound": tag})
    if args.cidr:
        rules.append({"ip_cidr": split_list(args.cidr), "outbound": tag})
    if args.domains:
        rules.append({"domain_suffix": split_list(args.domains), "outbound": tag})
    if not rules and not args.final:
        die("say which traffic goes to it: --final, --apps, --cidr and/or --domains")
    r = {"rules": rules}
    if args.final:
        r["final"] = tag
    return r


# --- WireGuard (wg-quick format) ---------------------------------------------

def parse_wg(text):
    iface, peers, cur = {}, [], None
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            sec = line.strip("[]").strip().lower()
            if sec == "interface":
                cur = iface
            elif sec == "peer":
                cur = {}
                peers.append(cur)
            else:
                die(f"unknown section [{sec}]")
            continue
        if "=" not in line or cur is None:
            die(f"cannot parse line {line!r}")
        k, v = (x.strip() for x in line.split("=", 1))
        k = k.lower()
        # Address/AllowedIPs/DNS may repeat; join them.
        cur[k] = f"{cur[k]},{v}" if k in cur and k in ("address", "allowedips", "dns") else v
    if "privatekey" not in iface:
        die("no PrivateKey in [Interface]")
    if not peers:
        die("no [Peer]")
    return iface, peers


def prefix(a):
    """wg-quick takes a bare address as a host route; sing-box wants the length.
    (PIA's generated configs write `Address = 10.13.128.2`.)"""
    return a if "/" in a else a + ("/128" if ":" in a else "/32")


def wg_endpoint(iface, peers, tag):
    ep = {"type": "wireguard", "tag": tag,
          "address": [prefix(a) for a in split_list(iface["address"])] if "address" in iface else die("no Address in [Interface]"),
          "private_key": iface["privatekey"], "peers": []}
    if "mtu" in iface:
        ep["mtu"] = int(iface["mtu"])
    for p in peers:
        if "endpoint" not in p:
            die("a [Peer] has no Endpoint -- a client config needs one")
        host, port = host_port(p["endpoint"])
        peer = {"address": host, "port": port, "public_key": p["publickey"],
                "allowed_ips": split_list(p.get("allowedips", "0.0.0.0/0, ::/0"))}
        if "presharedkey" in p:
            peer["pre_shared_key"] = p["presharedkey"]
        if "persistentkeepalive" in p:
            peer["persistent_keepalive_interval"] = int(p["persistentkeepalive"])
        ep["peers"].append(peer)
    return ep


def cmd_wg(args):
    iface, peers = parse_wg(open(args.conf).read())
    tag = args.tag or re.sub(r"[^a-z0-9]+", "-", os.path.splitext(os.path.basename(args.conf))[0].lower()).strip("-") or "wg"
    return {"_about": f"WireGuard, from {os.path.basename(args.conf)}",
            "endpoints": [wg_endpoint(iface, peers, tag)], "route": routing(args, tag)}


# --- X25519, for generating WireGuard keys without wg or any library ---------
# RFC 7748 Montgomery ladder; checked against `sing-box generate wg-keypair`.

def x25519(k, u=9):
    p, a24 = 2**255 - 19, 121665
    k = bytearray(k); k[0] &= 248; k[31] &= 127; k[31] |= 64
    n = int.from_bytes(k, "little")
    x1, x2, z2, x3, z3, swap = u, 1, 0, u, 1, 0
    for t in reversed(range(255)):
        kt = (n >> t) & 1
        swap ^= kt
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = kt
        A = (x2 + z2) % p; AA = A * A % p; B = (x2 - z2) % p; BB = B * B % p; E = (AA - BB) % p
        C = (x3 + z3) % p; D = (x3 - z3) % p; DA = D * A % p; CB = C * B % p
        x3 = (DA + CB) ** 2 % p; z3 = x1 * (DA - CB) ** 2 % p
        x2 = AA * BB % p; z2 = E * (AA + a24 * E) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def wg_keypair():
    priv = os.urandom(32)
    return base64.b64encode(priv).decode(), base64.b64encode(x25519(priv)).decode()


# --- Outline / Shadowsocks ---------------------------------------------------

def b64d(s):
    s = s.replace("-", "+").replace("_", "/")
    return base64.b64decode(s + "=" * (-len(s) % 4)).decode()


def cmd_ss(args):
    u = args.url.strip()
    if not u.startswith("ss://"):
        die("not an ss:// key")
    body, _, name = u[5:].partition("#")
    body, _, query = body.partition("?")
    body = body.rstrip("/")
    if "plugin=" in query:
        die("ss:// keys with a plugin are not supported here")
    if "@" in body:                       # SIP002: base64(method:password)@host:port
        cred, hp = body.rsplit("@", 1)
        cred = urllib.parse.unquote(cred)
        method, password = (cred if ":" in cred else b64d(cred)).split(":", 1)
    else:                                 # legacy: base64(method:password@host:port)
        method_pw, hp = b64d(body).rsplit("@", 1)
        method, password = method_pw.split(":", 1)
    host, port = host_port(hp)
    tag = args.tag or (re.sub(r"[^a-z0-9]+", "-", urllib.parse.unquote(name).lower()).strip("-") or "outline")
    return {"_about": f"Shadowsocks / Outline key {urllib.parse.unquote(name) or host}",
            "outbounds": [{"type": "shadowsocks", "tag": tag, "server": host, "server_port": port,
                           "method": method, "password": password}],
            "route": routing(args, tag)}


# --- NordVPN (NordLynx is WireGuard) -----------------------------------------
#
# Nord publishes no WireGuard configs; the key comes from its API, the way
# gluetun and others do it. UNOFFICIAL -- it can change without notice.
# Access token: Nord Account -> NordVPN -> Manual setup -> access token.

NORD = "https://api.nordvpn.com/v1"


def nord_get(path, token=None):
    req = urllib.request.Request(f"{NORD}{path}", headers={"User-Agent": "globaltun"})
    if token:
        req.add_header("Authorization", "Basic " + base64.b64encode(f"token:{token}".encode()).decode())
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def nord_server(country):
    q = "filters[servers_technologies][identifier]=wireguard_udp&limit=1"
    if country:
        ids = [c["id"] for c in nord_get("/servers/countries") if c["code"].lower() == country.lower()]
        if not ids:
            die(f"NordVPN has no country {country!r}")
        q += f"&filters[country_id]={ids[0]}"
    servers = nord_get(f"/servers/recommendations?{q}")
    if not servers:
        die("NordVPN recommended no WireGuard server")
    s = servers[0]
    tech = next(t for t in s["technologies"] if t["identifier"] == "wireguard_udp")
    pub = next(m["value"] for m in tech["metadata"] if m["name"] == "public_key")
    return s["hostname"], s["station"], pub


def cmd_nordvpn(args):
    try:
        creds = nord_get("/users/services/credentials", args.token)
    except urllib.error.HTTPError as e:
        die(f"NordVPN refused the token ({e.code}) -- make a new one in Nord Account")
    key = creds.get("nordlynx_private_key") or die("no nordlynx_private_key in Nord's answer")
    hostname, ip, pub = nord_server(args.country)
    tag = args.tag or "nordvpn"
    print(f"  NordVPN server: {hostname} ({ip})", file=sys.stderr)
    return {"_about": f"NordVPN NordLynx via {hostname}. Rerun vpn2singbox.py nordvpn for another server.",
            "endpoints": [{"type": "wireguard", "tag": tag, "address": ["10.5.0.2/32"],
                           "private_key": key,
                           "peers": [{"address": ip, "port": 51820, "public_key": pub,
                                      "allowed_ips": ["0.0.0.0/0", "::/0"]}]}],
            "route": routing(args, tag)}


# --- Cloudflare WARP (WireGuard) --------------------------------------------
#
# Registers a new anonymous WARP device with Cloudflare's client API -- what
# the 1.1.1.1 app and wgcf do. Free, no account. UNOFFICIAL like Nord's: the
# API can change without notice. WARP+ / Zero Trust licences are not handled.

WARP = "https://api.cloudflareclient.com/v0a2158"


def cmd_warp(args):
    import datetime
    priv, pub = wg_keypair()
    body = json.dumps({"key": pub, "install_id": "", "fcm_token": "", "model": "PC",
                       "serial_number": "", "locale": "en_US",
                       "tos": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")}).encode()
    req = urllib.request.Request(f"{WARP}/reg", data=body, method="POST", headers={
        "User-Agent": "okhttp/3.12.1", "CF-Client-Version": "a-6.10-2158", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            reg = json.load(r)
    except urllib.error.HTTPError as e:
        die(f"WARP registration refused ({e.code})")
    cfg = reg["config"]
    peer = cfg["peers"][0]
    # The IPv4 literal, so the endpoint needs no DNS; the port is the host's.
    port = int(peer["endpoint"]["host"].rsplit(":", 1)[1])
    ip = peer["endpoint"].get("v4", "").rsplit(":", 1)[0] or peer["endpoint"]["host"].rsplit(":", 1)[0]
    addrs = cfg["interface"]["addresses"]
    tag = args.tag or "warp"
    p = {"address": ip, "port": port, "public_key": peer["public_key"],
         "allowed_ips": ["0.0.0.0/0", "::/0"]}
    # client_id -> the 3 "reserved" bytes WARP routes by; some networks need them.
    if cfg.get("client_id"):
        p["reserved"] = list(base64.b64decode(cfg["client_id"]))[:3]
    return {"_about": f"Cloudflare WARP, device {reg.get('id', '?')} (anonymous, registered by vpn2singbox.py)",
            "endpoints": [{"type": "wireguard", "tag": tag,
                           "address": [prefix(addrs["v4"]), prefix(addrs["v6"])],
                           "private_key": priv, "mtu": 1280, "peers": [p]}],
            "route": routing(args, tag)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    def common(p):
        p.add_argument("--tag")
        p.add_argument("--final", action="store_true")
        p.add_argument("--apps"); p.add_argument("--cidr"); p.add_argument("--domains")
        p.add_argument("-o", "--out")
    p = sub.add_parser("wg"); p.add_argument("conf"); common(p); p.set_defaults(fn=cmd_wg)
    p = sub.add_parser("ss"); p.add_argument("url"); common(p); p.set_defaults(fn=cmd_ss)
    p = sub.add_parser("nordvpn"); p.add_argument("--token", required=True); p.add_argument("--country")
    common(p); p.set_defaults(fn=cmd_nordvpn)
    p = sub.add_parser("warp"); common(p); p.set_defaults(fn=cmd_warp)
    args = ap.parse_args()
    snippet = args.fn(args)
    text = json.dumps(snippet, indent=2) + "\n"
    if args.out:
        fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        print(f"  wrote {args.out} -- move it into vpns.d/ and run up", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
