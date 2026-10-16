# globaltun

Full tunnel — **TCP, UDP, QUIC/HTTP-3 and ICMP** — out through any box you can
ssh into, over an existing SSH path. On demand, never auto-started:
`sudo globaltun up` / `sudo globaltun down`.

For a network with no outbound path of its own.

```
this host --> [jumps...] --> gateway --> internet
```

`jumps` is a list and may be empty, so one module covers both shapes:

```
this host --LAN--> jump --OpenVPN--> phone gateway --> internet
this host --LAN--> server with its own uplink --> internet
```

**The gateway needs nothing installed** beyond an sshd and a writable `/tmp`.
The relay is pushed in as a static binary built for its architecture (`relay/`,
Go with CGO off: no libc, no dynamic loader, no interpreter). `rsocks.py` is
kept as a fallback for an architecture we do not ship or a `/tmp` mounted
noexec, and needs a `python3` there.

## Why it is built this way

The design is shaped by its hardest gateway: Termux + proot-distro on an
unrooted phone. PRoot fakes uid 0 via ptrace, but the kernel still sees an
unprivileged uid: no `CAP_NET_ADMIN`, no `CAP_NET_RAW`, no tun device, so
`ssh -w` is impossible. Such a gateway can only terminate and re-originate
**sockets**, never forward packets. Everything else follows — and because it
follows, an ordinary server works as a gateway with no changes at all.

`ssh -L` carries TCP only, and sshd will never `sendto()` for you, so UDP and
ICMP are multiplexed over TCP streams and re-emitted as real datagrams by the
relay — the only thing that runs on the gateway:

| stream | opened by | gateway does |
|---|---|---|
| SOCKS5 CONNECT | ordinary TCP | `connect()` |
| CONNECT `udp.mux.arpa:1` | `gtlocal.py` | `sendto`/`recvfrom` |
| CONNECT `icmp.mux.arpa:1` | `gticmp.py` | unprivileged ping socket |

Frame format on both mux streams: `[atyp][addr][port:2][len:2][payload]`.

**Not carried:** native SCTP and DCCP (absent from Android's kernel; proot
cannot load modules), and anything needing raw IP — GRE, ESP/AH. WebRTC works,
its SCTP riding inside DTLS over UDP.

sing-box is used **locally only**. On the gateway it wedges on
`initialize interface monitor take too much time`, staying alive with an empty
log while refusing every connection, because Android blocks netlink enumeration
for apps.

## Usage

```nix
my.globaltun = {
  enable = true;
  jumps  = [ ];                     # empty: dial the gateway directly
  remote = "user@192.0.2.50";       # the gateway, as seen from the LAST jump
  sshKey = "/path/to/key";          # a STRING -- see below
  remoteSocksPort = 1080;           # unique per client, no default
};
```

`jumps` is nearest-first and each entry is `[user@]host[:port]`, so a longer
chain is just a longer list:

```nix
  jumps = [ "user@jump.example" "admin@10.0.0.9:2222" ];
```

`sudo globaltun {up|down|status|verify|reload|reicmp|is-up|ssh-config}`.
`verify` exercises TCP, DNS, UDP, ICMP and reports the egress address.

The same scripts run standalone on a host that is not managed by this flake:
copy `globaltun*.sh` and the `.py` files somewhere, drop a `globaltun.env`
beside them exporting the same `GT_*` variables, and run it.

If the tools come from a Nix store on that host, **give them GC roots**.
`nix copy` transfers a path but roots nothing, so the next collection deletes it
and `up` fails on a missing binary:

```sh
nix-store --realise --add-root ~/globaltun/.deps/sing-box --indirect /nix/store/...-sing-box
```

Point `globaltun.env` at those symlinks rather than raw store paths. A host that
reaches the gateway without a jump sets `GT_JUMPS=-` (or just leaves it unset);
there is no separate script for that case.

## Options that are easy to get wrong

**`sshKey` is `types.str`, not `types.path`.** A path literal would be copied
into the world-readable Nix store; the type makes that inexpressible.

**`remoteSocksPort` has no default.** Several clients through one gateway must
not share a relay: whichever ran `up` last would kill the others' relay and
every connection on it, silently. A required option forces the choice.

The gateway is the registry, not this file — `pgrep -f 'gtrelay|rsocks'` there
shows what is actually bound (`ss` is blind under proot, where Android blocks
netlink). Four clients have been run concurrently on one phone at negligible
cost. The allocation is **per gateway**: changing gateways does not free the
numbers, it starts a new namespace.

**`keepDirect`** freezes prefixes onto the path they already use. Two things
belong there: on a headless machine, the network the admin session arrives over
— otherwise `up` cuts the connection mid-command and nothing is left to undo it
— and the underlay of any VPN the carrier depends on, since routing that into
the tunnel it carries survives only until the next rekey.

**The tunnel freezes the timezone.** `up` stops `automatic-timezoned` and `down`
starts it again. Not a convenience: a full tunnel makes this machine *appear* to
sit wherever the gateway's egress does, geoclue's BSSID lookup falls back to IP
geolocation when it has no data for the local APs, and the clock walks to
whatever that database thinks of the exit address — measured once as
`Africa/Libreville`, from a Cloudflare egress that two other databases place in
Korea. Freezing rather than correcting, because the timezone at `up` time was
decided on the real network and is already right, including after a real flight.

It restarts only what it stopped (a marker in `/run`), so a deliberately
disabled service stays disabled. With `my.locale.automatic = false` the unit is
not installed at all and this is a no-op — which is the correct behaviour, not a
coincidence worth guarding against. `GT_FREEZE_TZ=0` opts out in a standalone
bundle.

**`icmp.enable`** is separable because it is the only part touching policy
routing and netfilter: a second tun, an `ipproto icmp` rule, a routing table and
an interface-scoped exemption.

## Unrooted Android clients

`android/` carries what a phone needs. It cannot run the Linux half at all: no
`CAP_NET_ADMIN` means no tun and no routes. Android's sanctioned equivalent is
**`VpnService`**, which only an app may use — so sing-box's Android app owns the
tun and the routing, and `globaltun-termux.sh` supplies everything beneath it.

```
sing-box app (VpnService tun)
     |  socks5 127.0.0.1:1081
     v
gtlocal.py in Termux .......... UDP-ASSOCIATE over loopback, no privileges
     |  one TCP stream
     v
ssh -L  ->  the relay on the gateway
```

Nothing in the relays changes — the gateway relay and `gtlocal.py` are the same
files, referenced from the feature root rather than copied. Drop a
`gtrelay-linux-*` binary into the bundle and the phone pushes the static relay
too; without one it falls back to needing `python3` on the gateway.

**Match the binary to the GATEWAY's architecture, not the phone's.** The phone
is the client here: it only ever pushes the relay onward. With yulee as the
gateway the bundle needs `gtrelay-linux-amd64`, on an arm64 phone. Getting this
backwards is silent — `pick_relay` reads the gateway's `uname -m`, finds no
binary for it, and quietly falls back to `python3`.

**The tun inbound must exclude Termux** (`"exclude_package": ["com.termux"]`, as
shipped in `sing-box-android.json`). Otherwise ssh's own carrier is captured by
the tunnel it carries and nothing connects — the same failure as an unpinned VPN
underlay on a Linux host, expressed through Android's per-app list instead of a
route.

**Termux's own traffic is not tunnelled**, by the same exclusion. `pkg install`,
`git`, `curl` in that shell use the phone's direct network. Point them at the
proxy instead — `apt-proxy.conf.example` for apt, or
`export ALL_PROXY=socks5h://127.0.0.1:1081` for the rest. Use `socks5h` so the
proxy resolves names: local DNS is on the network that has no route out. ssh
ignores `ALL_PROXY`, so the carrier cannot end up looping through itself.

**ICMP is not carried.** `VpnService` grants one tun to one app, so there is
nowhere to put the second tun `gticmp.py` needs, and `ip rule` needs root. The
app answers pings itself, as sing-box did before `gticmp` existed.

### Setting one up

On the phone, in Termux (`pkg install openssh python`):

```sh
mkdir -p ~/globaltun && cd ~/globaltun
# from this repo: android/globaltun-termux.sh, android/globaltun.env.example,
#                 android/sing-box-android.json, rsocks.py, gtlocal.py,
#                 and optionally gtrelay-linux-{amd64,arm64}
cp globaltun.env.example globaltun.env && $EDITOR globaltun.env
ssh-keygen -t ed25519 -f ~/.ssh/globaltun -N ""      # add the .pub to both hops
./globaltun-termux.sh up
```

Then import `sing-box-android.json` into the sing-box app and start the VPN.
Keep the Termux session alive; toggle the VPN in the app as needed. Only re-run
`up` if the carrier drops.

**Android kills Termux's children.** On 12+ the phantom process killer reaps
them past a count of 32, which looks exactly like the carrier vanishing on its
own: `up` succeeds, starts the relay on the gateway, and the master is gone by
the time anything uses it. `termux-wake-lock` before `up` helps; the real fix is
`adb shell settings put global settings_enable_monitor_phantom_procs false`.
`globaltun.env` is the only file you edit; the script refuses to run without it
and prints the copy command. Give the phone its own `remoteSocksPort` like any
other client, and keep `GT_LOCAL_PORT` equal to the `server_port` of the app
config's socks outbound.

## Sharing the tunnel over Wi-Fi

`my.globaltun.share` adds `globaltun share`, which hosts an AP on this machine's
own card and routes its clients through the tunnel. A separate verb from `up`,
because the tunnel is useful without it and this touches the radio, the firewall
and forwarding.

```
sudo globaltun share          sudo globaltun share-status          sudo globaltun unshare
```

No NAT is involved: sing-box terminates each flow and re-originates it, then
writes the reply back to the tun addressed to the original client. Forwarding
plus two FORWARD rules is the whole data path.

**The card decides how hard this is.** Intel (iwlwifi) advertises
`#{ managed } <= 1, #{ AP, ... } <= 1`; MediaTek (mt7921) advertises
`#{ managed, P2P-client } <= 2, #{ AP } <= 1`. That one difference changes the
failure mode completely, and the *more* capable card fails in the worse way —
see the NetworkManager point below.

Five things make AP+STA on one radio harder than it looks, and all are handled:

**`iw ... interface add <n> type __ap` silently creates a *managed* vif.** That
trips `#{ managed } <= 1`, link-up fails with `EBUSY`, and it reads as the
driver refusing AP mode. The type has to be set *after* creation, while down.

**A too-old `iw` cannot parse `__ap` at all** and prints a usage dump. The
wrapper pins its own `iw`, so whatever is installed on the host is irrelevant.

**NetworkManager cannot drive this.** It does AP mode by asking wpa_supplicant
to flip a *managed* interface, which the same limit forbids; give it a ready
made AP vif and the supplicant refuses to grab it. hostapd directly is the only
route.

**Clients must reach the host before they can route through it** — DHCP `:67`
and DNS `:53`. Without an INPUT rule for the AP interface those are dropped
silently: hostapd completes the WPA handshake, the client shows "connected",
and dnsmasq never logs a DISCOVER because it never receives one. The client
then self-assigns an APIPA address, which is why DHCP is served rather than
left to static configuration — Windows has no static fallback.

**NetworkManager will steal the AP interface.** It matches saved profiles
against *any* wifi device, so the moment the AP vif appears NM may autoconnect
the upstream network to it — leaving the machine online through the interface
that was meant to serve clients, default route and all, with hostapd running
against a device NM has taken over. Only cards allowing two managed interfaces
can get into this state, so it is invisible on Intel and immediate on MediaTek.
Handled by `networking.networkmanager.unmanaged`, plus an `nmcli dev set …
managed no` in `share` for hosts that have not rebuilt.

Recovering a machine already in that state, in this order so the uplink never
drops: bring the upstream profile up on the station interface *first*, then set
the AP interface unmanaged.

`#channels <= 1` means the AP sits on the station's *current* channel, read when
`share` runs — so it drops whenever the upstream roams, and `share` must be run
again. `passwordFile` is a runtime path, never the passphrase, so the shared
secret stays out of the store.

## Windows clients

`windows/` carries what a Windows machine needs. Unlike Android this is close to
the Linux path: sing-box has a native build that drives a **Wintun** device and
the routing table, and Administrator is obtainable — so one process does what
`sing-box` + `ip route` do on Linux, and `globaltun-windows.ps1` supplies the
carrier and the mux around it.

```
sing-box (Wintun tun, auto_route)
     |  socks5 127.0.0.1:1081
     v
gtlocal.py ......... UDP-ASSOCIATE over loopback
     |  one TCP stream
     v
ssh -L  ->  the relay on the gateway
```

Two differences from the Linux scripts, both load-bearing:

**Windows OpenSSH has no `ControlMaster`.** There is no control socket to check
or to close, so the carrier is a plain `ssh -N -L` tracked by PID, and stopping
the remote relay needs its own connection.

**The carrier is pinned with a real route, not a sing-box rule.** sing-box's
`direct` outbound only covers traffic it sees; `ssh.exe` is a separate process
whose packets `auto_route` would capture. The script adds a `/32` via the
current next hop *before* anything creates the tun, into `ActiveStore` so a
reboot clears it. `status` reports `MISSING` if that pin is gone.

Requires: `sing-box.exe` with **`wintun.dll` beside it** (without it sing-box
exits immediately), Python for `gtlocal.py`, and an elevated shell. ICMP is not
carried — `gticmp.py` needs a second tun and `ip rule`, neither of which exists
here.

## Two traps worth knowing

**`ssh -J` does not pass `-i` to the jump hosts.** ssh(1) applies command-line
options to the destination only, so under `-J` every hop silently falls back to
password auth on every connection. Each prompt holds an unauthenticated slot on
that sshd for the whole `LoginGraceTime`; enough at once crosses `MaxStartups`
and it starts dropping *new* connections — which looks like a network outage and
heals by itself. Hence the explicit `ProxyCommand`.

**Reverse-path validation carries no protocol.** `ip rule add ipproto icmp`
steers outgoing ICMP correctly, but when a reply arrives the kernel looks up the
route *to its source* with no protocol set, so that rule cannot match; it falls
through to `main`, finds the tunnel device, and drops the packet. `tcpdump` shows
a perfect packet, netfilter counters show it accepted, and `InEchoReps` never
moves. The fix is a second rule keyed on the tun's own address.

## Performance

TCP is sub-second; HTTP/3 measured ~93 KB/s. Slow by nature — TCP-over-TCP, two
nested congestion-control loops on the same loss, and every syscall on the
gateway ptraced by proot. That same tax keeps CPU cost negligible: three
concurrent tunnels measured under 1.3% of an 8-core phone.
