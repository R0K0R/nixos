#!/usr/bin/env python3
"""Render the sing-box APP profile for an Android globaltun client.

Android gives the VPN slot to exactly one app. This makes sing-box that app and
puts every other VPN INSIDE it:

  base       sing-box-android.json -- the tun, exclude_package, the ssh socks
  + QUIC     a Hysteria2 outbound beside the ssh socks, behind a switch
             ("proxy": quic by default) that Termux's watcher flips to ssh
             while QUIC is down and back once it is healthy
  + vpns.d/  any number of snippets (Tailscale, WireGuard providers, OpenConnect,
             Outline, Tor, ...), each an endpoint/outbound plus the routing
             rules that send traffic to it

Every snippet endpoint/outbound without its own `detour` gets detour=proxy: its
underlay -- control plane, handshakes, encrypted packets -- rides globaltun, so
it works on a network with no uplink of its own. That is the whole point: the
Tailscale or NordVPN app alone is useless exactly where globaltun is needed.

Snippet format (vpns/*.json in the repo are templates; copy one into vpns.d/
and fill it in -- keys starting with "_" are documentation and are dropped):

  {
    "_about": "...",
    "endpoints": [ ... ],          sing-box endpoints (wireguard, tailscale, openconnect)
    "outbounds": [ ... ],          sing-box outbounds (shadowsocks, tor, ...)
    "dns":   { "servers": [...], "rules": [...] },   merged; rules go first
    "route": { "rules": [...],     inserted ahead of the base rules
               "final": "<tag>" }  optional: make this VPN the default exit
                                   (at most one snippet may); DNS follows it
    "toggle": false                optional: no on/off switch (see below)
  }

Each VPN gets an on/off SWITCH: a selector "<tag>-switch" of [<tag>, proxy],
which its rules (and route.final) point at instead of the VPN itself. The
sing-box app shows selectors in its groups view; tapping "proxy" turns the VPN
off live -- its traffic falls back to plain globaltun -- with no re-import, and
the app remembers the choice (cache_file). For a tailnet, "off" still reaches
it: the gateway is a tailnet node itself.

Any string still containing "@FILL" is refused, naming the file.
"""
import argparse, glob, json, os, sys


def strip_docs(v):
    if isinstance(v, dict):
        return {k: strip_docs(x) for k, x in v.items() if not k.startswith("_")}
    if isinstance(v, list):
        return [strip_docs(x) for x in v]
    return v


def die(msg):
    print(f"render-profile: {msg}", file=sys.stderr)
    sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--local-port", type=int, required=True,
                    help="where gtlocal really listens (the ssh path's socks)")
    ap.add_argument("--quic", nargs=4, metavar=("HOST", "PORT", "PASSWORD_FILE", "CERT_FILE"))
    ap.add_argument("--api", nargs=2, metavar=("LISTEN", "SECRET_FILE"),
                    help="sing-box's API on the phone's loopback, for the watcher")
    ap.add_argument("--extras", help="directory of enabled snippets (vpns.d)")
    a = ap.parse_args()

    c = json.load(open(a.template))
    socks = next(o for o in c["outbounds"] if o["type"] == "socks")
    # The port gtlocal really listens on, not whatever the template says.
    socks["server_port"] = a.local_port

    if a.quic:
        host, port, pwf, certf = a.quic
        socks["tag"] = "ssh"
        quic = {"type": "hysteria2", "tag": "quic", "server": host, "server_port": int(port),
                "password": open(pwf).read().strip(),
                # Inline: the app cannot read a path in Termux's storage.
                "tls": {"enabled": True, "server_name": "globaltun",
                        "certificate": open(certf).read().strip().splitlines()}}
        # A switch, not a urltest: urltest keeps its pick until another member
        # beats it by the tolerance, and the ssh probe can measure faster than
        # QUIC, so one QUIC hiccup parked traffic on ssh for good (seen on this
        # phone 2026-11-17). Termux's watcher steers it instead.
        group = {"type": "selector", "tag": "proxy", "outbounds": ["quic", "ssh"],
                 "default": "quic", "interrupt_exist_connections": True}
        c["outbounds"] = [quic, socks, group] + [o for o in c["outbounds"] if o["type"] != "socks"]
        # QUIC carries UDP natively: DNS passes through instead of being
        # answered locally (the hijack exists for the udp-over-tcp path only).
        c["route"]["rules"] = [r for r in c["route"]["rules"] if r.get("action") != "hijack-dns"]

    files = sorted(glob.glob(os.path.join(a.extras, "*.json"))) if a.extras else []
    tags = {o["tag"] for o in c["outbounds"]}
    front_rules, dns_rules, final, final_from, switches = [], [], None, None, []
    for f in files:
        name = os.path.basename(f)
        try:
            raw = json.load(open(f))
        except ValueError as e:
            die(f"{name}: not valid JSON ({e})")
        x = strip_docs(raw)
        toggle = x.pop("toggle", True)
        if "@FILL" in json.dumps(x):
            die(f"{name}: still has @FILL placeholders -- fill them in or remove the file")
        for kind in ("endpoints", "outbounds"):
            for o in x.get(kind, []):
                if o.get("tag") in tags:
                    die(f"{name}: tag {o.get('tag')!r} is already used")
                tags.add(o["tag"])
                # Ride globaltun unless the snippet says otherwise.
                o.setdefault("detour", "proxy")
                c.setdefault(kind, [])
                # Outbounds go ahead of "direct" so the list reads in order.
                if kind == "outbounds":
                    c[kind].insert(len(c[kind]) - 1, o)
                else:
                    c[kind].append(o)
        d = x.get("dns", {})
        c["dns"]["servers"] += d.get("servers", [])
        dns_rules += d.get("rules", [])
        r = x.get("route", {})
        vpn = next((o["tag"] for k in ("endpoints", "outbounds") for o in x.get(k, [])), None)
        if toggle and vpn:
            sw = f"{vpn}-switch"
            if sw in tags:
                die(f"{name}: tag {sw!r} is already used")
            tags.add(sw)
            c["outbounds"].insert(len(c["outbounds"]) - 1, {
                "type": "selector", "tag": sw, "outbounds": [vpn, "proxy"], "default": vpn,
                # Switching cuts the connections on the old path, so they
                # redial on the new one instead of hanging on it.
                "interrupt_exist_connections": True})
            for rule in r.get("rules", []):
                if rule.get("outbound") == vpn:
                    rule["outbound"] = sw
            if r.get("final") == vpn:
                r["final"] = sw
            switches.append(sw)
        front_rules += r.get("rules", [])
        if r.get("final"):
            if final:
                die(f"{name}: route.final {r['final']!r}, but {final_from} already set {final!r}; only one VPN can be the default exit")
            final, final_from = r["final"], name
        print(f"  vpn: {name} -> {', '.join(o['tag'] for k in ('endpoints', 'outbounds') for o in x.get(k, []))}")

    if front_rules:
        # After sniff (rule 0), ahead of the base rules -- which send the
        # tailnet range and private ranges direct, and would win otherwise.
        rules = c["route"]["rules"]
        i = 1 if rules and rules[0].get("action") == "sniff" else 0
        c["route"]["rules"] = rules[:i] + front_rules + rules[i:]
    if dns_rules:
        c["dns"]["rules"] = dns_rules + c["dns"].get("rules", [])
    # Server NAMES (a VPN's endpoint hostname, the OpenConnect portal) need a
    # resolver of their own, and it must NOT be remote-dns: when a VPN is the
    # default exit, remote-dns goes through it, and resolving that VPN's own
    # server through the VPN can never succeed. bootstrap-dns always rides
    # globaltun itself. (sing-box 1.12+ requires the resolver to be explicit.)
    c["dns"]["servers"].append({"type": "https", "tag": "bootstrap-dns", "server": "1.1.1.1", "detour": "proxy"})
    c["route"]["default_domain_resolver"] = "bootstrap-dns"
    if final:
        c["route"]["final"] = final
        # The default exit's DNS goes the same way, or every lookup would leak
        # around the VPN that is supposed to hide it.
        for s in c["dns"]["servers"]:
            if s.get("tag") == "remote-dns":
                s["detour"] = final

    if a.api:
        # Loopback -- but on a phone every app shares it, and this API can
        # switch transports, so it takes a secret.
        c.setdefault("experimental", {})["clash_api"] = {
            "external_controller": a.api[0], "secret": open(a.api[1]).read().strip()}
    if switches:
        # Remembers each switch's position across app restarts. It cannot leave
        # one selector out, so "proxy" is remembered too: an app restarted while
        # parked on ssh comes back on ssh -- and the watcher (`up` starts it)
        # brings it back to QUIC within ~30 s. Without switches, no cache: a
        # fresh start is always QUIC.
        c.setdefault("experimental", {})["cache_file"] = {"enabled": True}
        print(f"  switches (app -> groups): {', '.join(switches)}")

    with open(a.out, "w") as fh:
        json.dump(c, fh, indent=2)
    os.chmod(a.out, 0o600)


if __name__ == "__main__":
    main()
