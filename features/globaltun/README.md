# globaltun

Full tunnel — **TCP, UDP, QUIC/HTTP-3 and ICMP** — out through a phone acting as
the gateway, over an existing SSH path. On demand, never auto-started:
`sudo globaltun up` / `sudo globaltun down`.

For a network with no outbound path of its own, where some other machine can
still reach a phone that does have one.

```
this host --LAN--> jump host --(its uplink)--> phone gateway --> internet
```

## Why it is built this way

The gateway is Termux + proot-distro. PRoot fakes uid 0 via ptrace, but the
kernel still sees an unprivileged uid: no `CAP_NET_ADMIN`, no `CAP_NET_RAW`, no
tun device, so `ssh -w` is impossible. The gateway can only terminate and
re-originate **sockets**, never forward packets. Everything else follows.

`ssh -L` carries TCP only, and sshd will never `sendto()` for you, so UDP and
ICMP are multiplexed over TCP streams and re-emitted as real datagrams by a
small Python relay (`rsocks.py`) — the only thing that runs on the gateway:

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
  jump   = "user@jump.example";     # must be able to reach `remote`
  remote = "root@192.0.2.50";       # the phone, as seen FROM the jump host
  sshKey = "/path/to/key";          # a STRING -- see below
  remoteSocksPort = 1080;           # unique per client, no default
};
```

`sudo globaltun {up|down|status|verify|reload|reicmp|is-up}`.
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

Point `globaltun.env` at those symlinks rather than raw store paths. A host that reaches
the gateway *without* a jump — one holding the VPN link itself — uses
`globaltun-direct.sh`.

## Options that are easy to get wrong

**`sshKey` is `types.str`, not `types.path`.** A path literal would be copied
into the world-readable Nix store; the type makes that inexpressible.

**`remoteSocksPort` has no default.** Several clients through one gateway must
not share a relay: whichever ran `up` last would kill the others' relay and
every connection on it, silently. A required option forces the choice.

The gateway is the registry, not this file — `pgrep -f rsocks` there shows what
is actually bound (`ss` is blind under proot). Four clients have been run
concurrently on one phone at negligible cost.

**`keepDirect`** freezes prefixes onto the path they already use. Two things
belong there: on a headless machine, the network the admin session arrives over
— otherwise `up` cuts the connection mid-command and nothing is left to undo it
— and the underlay of any VPN the carrier depends on, since routing that into
the tunnel it carries survives only until the next rekey.

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
ssh -L  ->  rsocks.py on the gateway
```

Nothing in the relays changes — `rsocks.py` and `gtlocal.py` are the same files,
referenced from the feature root rather than copied.

**The tun inbound must exclude Termux** (`"exclude_package": ["com.termux"]`, as
shipped in `sing-box-android.json`). Otherwise ssh's own carrier is captured by
the tunnel it carries and nothing connects — the same failure as an unpinned VPN
underlay on a Linux host, expressed through Android's per-app list instead of a
route.

**ICMP is not carried.** `VpnService` grants one tun to one app, so there is
nowhere to put the second tun `gticmp.py` needs, and `ip rule` needs root. The
app answers pings itself, as sing-box did before `gticmp` existed.

### Setting one up

On the phone, in Termux (`pkg install openssh python`):

```sh
mkdir -p ~/globaltun && cd ~/globaltun
# from this repo: android/globaltun-termux.sh, android/globaltun.env.example,
#                 android/sing-box-android.json, rsocks.py, gtlocal.py
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

## Two traps worth knowing

**`ssh -J` does not pass `-i` to the jump host.** ssh(1) applies command-line
options to the destination only, so under `-J` the jump silently falls back to
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
