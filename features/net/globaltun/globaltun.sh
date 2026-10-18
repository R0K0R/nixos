#!/usr/bin/env bash
# globaltun - full tunnel (TCP/UDP/QUIC/ICMP) over an SSH path to an unprivileged
# Termux/proot phone acting as the internet gateway. See globaltun-findings.md.
#
#   up      : bring the whole tunnel up (idempotent)
#   down    : tear it down and restore normal routing
#   status  : show carrier, relays, tun devices, routes, egress IP
#   verify  : end-to-end checks (TCP / DNS / UDP / ICMP / tailscale)
#   reload  : restart only the local sing-box (keeps ssh master + phone relay)
#   reicmp  : restart only the ICMP relay and its policy routing
#   is-up   : exit 0 if the tunnel is carrying traffic (for automation)
#   share   : host a Wi-Fi AP on this card and route its clients through the tunnel
#   unshare : stop it
#   ssh-config : path to the generated jump chain (empty when there are none)
#
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

# A standalone bundle carries its configuration beside the script. The NixOS
# wrapper exports the same variables directly and ships no such file.
#
# NOT named "env": installed into a bin directory, $HERE/env resolves to
# coreutils' env BINARY, and sourcing that fails with "cannot execute binary
# file". The name has to be one nothing else in a PATH directory can claim.
[ -f "$HERE/globaltun.env" ] && . "$HERE/globaltun.env"

# Endpoints carry no defaults on purpose: a wrong-but-plausible gateway fails as
# a timeout deep in the connection, which reads as a network fault rather than a
# misconfiguration. `:?` makes an unset one fail immediately and by name.
RHOST=${GT_RHOST:?set GT_RHOST, e.g. root@gateway}
KEY=${GT_KEY:?set GT_KEY, path to the ssh private key}
RPORT=${GT_RPORT:-2022}

# Hops, in order, nearest first: this machine -> hops[0] -> hops[1] -> ... ->
# gateway. Space- or comma-separated. Each token is one of
#
#   [user@]host[:port][=AUTH]                 an ssh jump
#   socks5://[user@]host:port[=password:FILE] a SOCKS5 proxy (Tor: 127.0.0.1:9050)
#   http://[user@]host:port[=password:FILE]   an HTTP CONNECT proxy
#
# where an ssh jump's AUTH is `key` (the default: GT_KEY), `key:FILE` (a key
# of its own), or `password:FILE`. FILE is always a path to the secret, never
# the secret: tokens end up in ps output and in the generated ssh config.
#
# An EMPTY list is a first-class case, not a degenerate one: a machine that
# already holds the link to the gateway reaches it directly, and the gateway
# may itself be the box with the internet. GT_JUMP (singular) is still read so
# an older standalone globaltun.env keeps working.
JUMPS=${GT_JUMPS:-${GT_JUMP:-}}
JUMP_TIMEOUT=${GT_JUMP_TIMEOUT:-120}
# "-" lets a config file say "no jumps" explicitly rather than by omission.
[ "$JUMPS" = "-" ] && JUMPS=""
JUMP_LIST=()
# Unquoted on purpose: word splitting IS the parse.
for _j in ${JUMPS//,/ }; do JUMP_LIST+=("$_j"); done

# Parse every hop up front, so a malformed one fails here, by name, instead of
# as an opaque ssh error two hops into the chain.
H_KIND=() H_USER=() H_HOST=() H_PORT=() H_AUTH=() H_SECRET=()
parse_hop(){
  local tok=$1 spec auth="" kind=ssh user="" host port="" method="" secret=""
  spec=${tok%%=*}
  [ "$spec" != "$tok" ] && auth=${tok#*=}
  case $spec in
    socks5://*) kind=socks5; spec=${spec#socks5://} ;;
    http://*)   kind=http;   spec=${spec#http://} ;;
    *://*)      echo "hop '$tok': unknown scheme (ssh, socks5://, http://)" >&2; return 1 ;;
  esac
  case $spec in *@*) user=${spec%%@*}; spec=${spec#*@} ;; esac
  host=${spec%%:*}
  [ "$host" != "$spec" ] && port=${spec#*:}
  [ -n "$host" ] || { echo "hop '$tok': no host" >&2; return 1; }
  case $kind in
    ssh) port=${port:-22} ;;
    *)   [ -n "$port" ] || { echo "hop '$tok': a proxy needs an explicit port" >&2; return 1; } ;;
  esac
  case $port in *[!0-9]*) echo "hop '$tok': bad port '$port'" >&2; return 1 ;; esac

  if [ -n "$auth" ]; then method=${auth%%:*}; [ "$method" != "$auth" ] && secret=${auth#*:}; fi
  case $kind:$method in
    ssh:|ssh:key)  method=key; secret=${secret:-$KEY} ;;
    ssh:password|socks5:password|http:password)
      [ -n "$secret" ] || { echo "hop '$tok': password needs a file, password:/path" >&2; return 1; } ;;
    socks5:|http:) method="" ;;
    *) echo "hop '$tok': auth '$method' is not valid for a $kind hop" >&2; return 1 ;;
  esac
  if [ "$method" = password ]; then
    [ "$kind" = ssh ] || [ -n "$user" ] \
      || { echo "hop '$tok': proxy password auth needs user@" >&2; return 1; }
    [ -r "$secret" ] || { echo "hop '$tok': cannot read password file $secret" >&2; return 1; }
    # Warn, the way ssh refuses a key with loose permissions -- but only warn:
    # this runs as root, and refusing would strand a tunnel over a mode bit.
    case $(stat -c %a "$secret" 2>/dev/null) in
      *[1-7][0-7]|*[1-7]) echo "warning: $secret is readable by group/others" >&2 ;;
    esac
  fi
  H_KIND+=("$kind") H_USER+=("$user") H_HOST+=("$host") H_PORT+=("$port")
  H_AUTH+=("$method") H_SECRET+=("$secret")
}
for _j in "${JUMP_LIST[@]}"; do parse_hop "$_j" || exit 1; done

# The host whose route must NOT be swallowed by the tun it carries -- i.e. the
# one THIS machine opens a socket to: the first hop, whatever kind it is, or
# the gateway itself if there are none.
if [ ${#H_HOST[@]} -gt 0 ]; then CARRIER=${H_HOST[0]}
else CARRIER=${RHOST##*@}; CARRIER=${CARRIER%%:*}
fi

# Component paths. Set by the NixOS wrapper to store paths; fall back to files
# beside this script so a checkout still runs standalone.
: "${GT_RSOCKS:=$HERE/rsocks.py}"
: "${GT_GTCONNECT:=$HERE/gtconnect.py}"
# Static, dependency-free relay binaries, one per architecture. See
# start_remote_relay: these are what make the gateway prerequisite-free.
: "${GT_RELAY_DIR:=$HERE}"
: "${GT_GTLOCAL:=$HERE/gtlocal.py}"
: "${GT_GTICMP:=$HERE/gticmp.py}"
: "${GT_SBCONF:=$HERE/gt-client.json}"
: "${GT_SINGBOX:=$HERE/sing-box}"
: "${GT_VERIFY:=$HERE/verify.py}"
GT_ICMP=${GT_ICMP:-1}

LPORT=11080              # local end of ssh -L -> remote sing-box
RPORT_SS=${GT_REMOTE_SOCKS_PORT:-1080}   # relay port ON the gateway
# Distinct per client: two hosts tunnelling through the same gateway would
# otherwise share one relay and one pidfile, and whichever ran `up` second
# would kill the other's relay along with every connection on it.
TUN=tun9
CTL=/run/globaltun.ctl
PIDF=/run/globaltun-singbox.pid
GLPID=/run/globaltun-gtlocal.pid
GLLOG=/var/log/globaltun-gtlocal.log
LOCAL_PORT=1081
ICPID=/run/globaltun-gticmp.pid
ICLOG=/var/log/globaltun-gticmp.log
ICTUN=tun8
# Both tun subnets are overridable: 172.19/16 is a common Docker bridge range,
# and a host already using it would have the two fight over the same address.
IC_ADDR=${GT_ICMP_ADDR:-172.19.1.1/30}
TUNADDR_IP=${IC_ADDR%%/*}
IC_TABLE=101
TS_TABLE=102
TS_PRIO=5205
IC_PRIO=5240
LOG=/var/log/globaltun.log
STATE=/run/globaltun.state

SSHOPTS=(-i "$KEY" -p "$RPORT"
         -o StrictHostKeyChecking=accept-new
         -o ServerAliveInterval=30 -o ServerAliveCountMax=10
         -o ExitOnForwardFailure=yes
         -o ControlPersist=10m)

# Every hop's credentials have to be handed to it EXPLICITLY. ssh(1) applies
# command-line options to the DESTINATION only, so under a plain `-J` list each
# jump silently falls back to password auth on every connection -- which parks
# unauthenticated slots on its sshd until MaxStartups starts dropping new
# connections outright, a failure that looks exactly like a network outage.
#
# The chain is ProxyCommand per hop, not ProxyJump, and that is what makes the
# other auth methods and hop kinds possible at all. Under ProxyJump the ssh
# that authenticates to a hop is spawned INSIDE ssh, where nothing can reach
# it: no way to hand it a password, and no way to put a proxy in front of it.
# With ProxyCommand, the process that reaches each hop is one this script
# wrote, so a password hop gets its askpass and a proxy hop gets gtconnect.
#
# This does not bring back the nested-quoting problem that one inline
# ProxyCommand per hop would have: each hop's command lives in its OWN Host
# block, and refers to the hop before it by name, so nothing is quoted inside
# anything -- with one exception, gtconnect's --via, which is a single level.
: "${GT_SSHCFG:=}"
if [ -z "$GT_SSHCFG" ]; then
  # /run is the right place -- cleared on boot, so a stale chain cannot
  # outlive a reconfiguration -- but Termux has no /run and runs unrooted.
  if [ -w /run ]; then GT_SSHCFG=/run/globaltun.ssh_config
  else                 GT_SSHCFG=${TMPDIR:-/tmp}/globaltun-$(id -u).ssh_config
  fi
fi
ASKPASS=$GT_SSHCFG.askpass
# Absolute, because ProxyCommand runs under whatever shell ssh picks and with
# whatever PATH that shell builds; resolving once here pins the exact binaries
# this script was started with.
SSH_BIN=$(command -v ssh)
PY_BIN=$(command -v python3 || true)

# How the process that reaches ssh hop $1 must be started, as a prefix. A
# password hop answers its prompt through SSH_ASKPASS, forced on so it needs no
# tty and no DISPLAY (OpenSSH 8.4+). The FILE travels in the environment, never
# the password.
hop_env(){
  [ "${H_AUTH[$1]}" = password ] || return 0
  printf 'env GT_PASSFILE=%s SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force ' "${H_SECRET[$1]}" "$ASKPASS"
}

ssh_via_hop(){   # ssh_via_hop INDEX TARGET -> a command whose stdio is a stream to TARGET
  echo "$(hop_env "$1")$SSH_BIN -F $GT_SSHCFG -W $2 gt-hop-$(($1 + 1))"
}

# The command whose stdio is a stream to TARGET, through hops [0, $2). Empty
# when there are no hops before it -- ssh then dials directly.
reach_cmd(){
  local target=$1 end=$2 last s k args=""
  [ "$end" -gt 0 ] || return 0
  last=$((end - 1))
  if [ "${H_KIND[$last]}" = ssh ]; then
    ssh_via_hop "$last" "$target"; return
  fi
  # A run of proxies ending at $last. gtconnect walks the whole run in one
  # process; the run's first proxy is dialed directly, or through the ssh hop
  # just before the run when there is one.
  s=$last
  while [ "$s" -gt 0 ] && [ "${H_KIND[$((s - 1))]}" != ssh ]; do s=$((s - 1)); done
  [ -n "$PY_BIN" ] || { echo "proxy hops need python3" >&2; return 1; }
  [ "$s" -gt 0 ] && args="--via '$(ssh_via_hop $((s - 1)) "${H_HOST[$s]}:${H_PORT[$s]}")'"
  for k in $(seq "$s" "$last"); do
    args="$args --proxy ${H_KIND[$k]} ${H_HOST[$k]} ${H_PORT[$k]} ${H_USER[$k]:--} ${H_SECRET[$k]:--}"
  done
  echo "$PY_BIN $GT_GTCONNECT $args --target $target"
}

write_ssh_config(){
  local i n pc
  umask 077
  : > "$GT_SSHCFG"
  for i in "${!H_KIND[@]}"; do
    [ "${H_KIND[$i]}" = ssh ] || continue   # proxies are folded into the next ProxyCommand
    n=$((i + 1))
    pc=$(reach_cmd "%h:%p" "$i") || return 1
    {
      echo "Host gt-hop-$n"
      echo "  HostName ${H_HOST[$i]}"
      [ -n "${H_USER[$i]}" ] && echo "  User ${H_USER[$i]}"
      echo "  Port ${H_PORT[$i]}"
      if [ "${H_AUTH[$i]}" = password ]; then
        # Password only. Offering keys first would spend MaxAuthTries on keys
        # this hop does not take, and one prompt means a wrong password fails
        # in one round trip instead of looping on the askpass.
        echo "  PubkeyAuthentication no"
        echo "  PreferredAuthentications keyboard-interactive,password"
        echo "  NumberOfPasswordPrompts 1"
      else
        echo "  IdentityFile ${H_SECRET[$i]}"
        # Without IdentitiesOnly, a loaded agent is offered first and a hop that
        # rejects those keys can exhaust MaxAuthTries before ours is ever tried.
        echo "  IdentitiesOnly yes"
      fi
      echo "  StrictHostKeyChecking accept-new"
      echo "  ConnectTimeout $JUMP_TIMEOUT"
      echo "  ServerAliveInterval 30"
      echo "  ServerAliveCountMax 10"
      [ -n "$pc" ] && echo "  ProxyCommand $pc"
    } >> "$GT_SSHCFG"
  done

  # Answers ONLY a password prompt. Anything else ssh might ask -- a changed
  # host key, a yes/no -- gets a refusal rather than the password, so a prompt
  # we did not anticipate can never leak it.
  if printf '%s\n' "${H_AUTH[@]}" | grep -qx password; then
    cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case $1 in *assword*) exec cat "$GT_PASSFILE" ;; esac
exit 1
EOF
    chmod 700 "$ASKPASS"
  fi
}

if [ ${#H_KIND[@]} -gt 0 ]; then
  write_ssh_config || { echo "cannot write $GT_SSHCFG" >&2; exit 1; }
  _pc=$(reach_cmd "%h:%p" ${#H_KIND[@]}) || exit 1
  # -F makes ssh read ONLY this file (plus the system one). Everything the
  # destination needs is already on the command line above, so nothing is lost.
  SSHOPTS+=(-F "$GT_SSHCFG" -o "ProxyCommand=$_pc")
fi

gw(){  ip route show default | awk '{print $3; exit}'; }

# Keep the ssh carrier out of the tunnel it carries. Its correct path is
# whatever the kernel would choose right now, which is NOT always the default
# gateway: with no jump host the carrier reaches the gateway over an OpenVPN
# tun, and forcing it via the default gw would cut the connection the tunnel
# depends on. Must run BEFORE the 0.0.0.0/1 routes exist, or it reads them back.
# Freeze a destination onto the path the kernel would choose RIGHT NOW, so the
# tun cannot swallow it. Must run BEFORE the 0.0.0.0/1 routes exist, or it reads
# them back and pins the prefix to the tunnel it is meant to bypass.
pin_prefix(){
  local target=$1 label=$2 probe line via dev
  probe=${target%%/*}
  line=$(ip route get "$probe" 2>/dev/null | head -1)
  [ -n "$line" ] || { echo "cannot resolve a route to $label $target" >&2; return 1; }
  via=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
  dev=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$dev" ] || { echo "no device in route to $label $target" >&2; return 1; }
  # `onlink` because the gateway may not be provably on-link: NetworkManager
  # sets noprefixroute on DHCP addresses, so the interface has NO connected
  # route and the kernel rejects any new route via that gateway with
  # "Nexthop has invalid gateway" -- even though its own default route uses it.
  # We are copying the path the kernel already takes, so asserting on-link is
  # exactly true.
  if [ -n "$via" ]; then ip route replace "$target" via "$via" dev "$dev" onlink
  else                   ip route replace "$target" dev "$dev"
  fi || { echo "FAILED to pin $label $target (${via:+via $via }dev $dev)" >&2; return 1; }
  echo "$label $target pinned ${via:+via $via }dev $dev"
}

# Tailscale marks its own WireGuard traffic 0x80000 and rule 5210 sends it to
# `main`, where our 0.0.0.0/1 now beats the default -- so the underlay goes
# through the tunnel, STUN reports the gateway's public address, peers cannot
# reach it, and even two machines on one LAN end up relaying via DERP.
#
# A rule ABOVE 5210 puts that traffic back on the physical link. The cost is
# that tailscale then needs the physical uplink: during an outage only LAN
# peers stay reachable, where riding the tun would have kept the whole tailnet
# (slowly). Which is right depends on the host, hence the switch.
#
# Measured on galaxybook, 2026-10-08: without this, a peer on the SAME /21
# relayed via DERP "sin" (Singapore) and had moved 9.6GB that way. With it, the
# same peer went `direct 172.20.1.7:41641` at 3-6ms. netcheck still reports
# `UDP: false` afterwards, because the physical network has no uplink at all
# and no STUN server is reachable -- on-LAN peers need only local endpoint
# discovery, so that is not a failure of the bypass.
tailscale_bypass(){
  [ "${GT_TAILSCALE_DIRECT:-0}" = 1 ] || return 0
  local g d
  g=$(gw); d=$(dev)
  [ -n "$g" ] && [ -n "$d" ] || { echo "no default route; skipping tailscale bypass" >&2; return 0; }
  # `onlink` as a fallback for the same reason pin_prefix needs it: with
  # NetworkManager's noprefixroute the interface has no connected route, so the
  # kernel rejects a route via that gateway with "Nexthop has invalid gateway"
  # even though its own default route uses it.
  #
  # Tolerant, because this runs inside `up` under set -e: a failure here must
  # cost tailscale its direct paths, not abort the tunnel half-built.
  #
  # The LAN only, not a default route. A default here took ALL of tailscaled's
  # marked traffic off the tun -- the control plane and DERP too -- so on a
  # network that blocks direct internet (the reason for the tunnel) `tailscale
  # login` hung on controlplane.tailscale.com:443 forever (2026-10-10). Anything
  # off the LAN falls through to rule 5210 and rides the tun; LAN peers, the
  # point of this switch, stay direct.
  local lan
  lan=$(ip -o -4 route show dev "$d" scope link | awk '{print $1; exit}')
  [ -n "$lan" ] || { echo "no LAN prefix on $d; skipping tailscale bypass" >&2; return 0; }
  if ! ip route replace "$lan" dev "$d" table $TS_TABLE 2>/dev/null; then
    echo "could not install the tailscale bypass route; peers will relay via DERP" >&2
    return 0
  fi
  ip rule del priority $TS_PRIO 2>/dev/null || true
  if ip rule add fwmark 0x80000/0xff0000 lookup $TS_TABLE priority $TS_PRIO 2>/dev/null; then
    echo "tailscale underlay kept on $d (table $TS_TABLE, prio $TS_PRIO)"
  else
    echo "could not install the tailscale bypass rule; peers will relay via DERP" >&2
  fi
}

pin_carrier(){
  pin_prefix "$CARRIER/32" carrier || return 1
  # On a headless box the session bringing this up arrives over some network;
  # if its return path is swallowed by the tun the connection dies mid-command
  # and nothing is left to run `down`. GT_KEEP_DIRECT lists prefixes to leave on
  # their existing path -- management networks, in practice.
  local p
  for p in ${GT_KEEP_DIRECT:-}; do pin_prefix "$p" keep-direct || true; done
}
dev(){ ip route show default | awk '{print $5; exit}'; }
need_root(){ [ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }; }
have_ctl(){ [ -S "$CTL" ] && ssh -S "$CTL" -O check "$RHOST" >/dev/null 2>&1; }

# Run a script on the gateway in a POSIX shell, read from stdin.
#
# `ssh host "some script"` hands the string to the gateway user's LOGIN shell,
# which is whatever that person chose -- yulee's is fish, where `P=/tmp/x` is a
# syntax error and the whole block dies on its first line. None of these
# snippets are written in fish, csh or anything else, and making them portable
# to every interactive shell is not a thing that can be finished.
#
# So the login shell gets exactly one word to exec, and the script arrives on
# stdin for /bin/sh to read. Nothing about the gateway's shell can reach it.
rsh(){ ssh -S "$CTL" "$RHOST" /bin/sh; }

# Same idea for a one-liner, where stdin is needed for something else: quote it
# so the login shell passes it through to /bin/sh -c intact.
rsh1(){ ssh -S "$CTL" "$RHOST" "/bin/sh -c '$1'"; }

master(){   # key auth on both hops; no password prompts
  have_ctl && return 0
  rm -f "$CTL"
  ss -ltn 2>/dev/null | grep -q ":$LPORT " && { echo "port $LPORT already in use -- run 'down' first" >&2; exit 1; }
  local n t err delay
  n=0
  err=$(mktemp)
  for t in ${GT_TIMEOUTS:-300 600 900}; do
    n=$((n+1))
    echo "master attempt $n (ConnectTimeout=${t}s)..." >&2
    # -f backgrounds after auth and takes stderr with it, so the real reason --
    # e.g. "connect failed: No route to host" from the jump host when its VPN to
    # the gateway is re-establishing -- never reaches the terminal. Capture it,
    # otherwise every distinct fault looks like "Connection closed".
    if env ALL_PROXY= ssh -M -S "$CTL" -f -N -o ConnectTimeout="$t" \
         -L "127.0.0.1:$LPORT:127.0.0.1:$RPORT_SS" "${SSHOPTS[@]}" "$RHOST" 2>"$err"; then
      have_ctl && { [ $n -gt 1 ] && echo "(master established on attempt $n)"; rm -f "$err"; return 0; }
    fi
    echo "master attempt $n failed: $(tr '\n' ' ' <"$err" | sed 's/  */ /g;s/ $//')" >&2
    rm -f "$CTL"
    # Backoff long enough to outlast a VPN re-establishment on the path. Three
    # attempts three seconds apart all land inside the same outage and prove
    # nothing; the whole point of retrying is to sample a different moment.
    delay=$(( n * ${GT_RETRY_DELAY:-20} ))
    [ $n -lt 3 ] && { echo "  retrying in ${delay}s" >&2; sleep "$delay"; }
  done
  rm -f "$err"
  echo "could not establish ssh master to $RHOST${JUMPS:+ via $JUMPS}. Reading the error above:" >&2
  echo "  'No route to host'   -> the hop BEFORE the gateway lost its path to it" >&2
  echo "  'Connection refused' -> the gateway is up but sshd is not listening" >&2
  echo "  'Connection closed'  -> the far end hung up; check it is not rate-limiting" >&2
  echo "  'timed out'          -> reachable but not answering; usually the gateway itself" >&2
  echo "Reproduce interactively with:" >&2
  echo "  ssh -v ${SSHOPTS[*]} $RHOST true" >&2
  exit 1
}



start_gtlocal(){
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null || true; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null || true
  sleep 0.3
  setsid python3 -u "$GT_GTLOCAL" >"$GLLOG" 2>&1 </dev/null &
  echo $! > "$GLPID"
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$LOCAL_PORT " \
    && echo "gtlocal up: $(head -1 "$GLLOG")" \
    || { echo "gtlocal FAILED:"; cat "$GLLOG"; exit 1; }
}

start_gticmp(){
  [ -f "$ICPID" ] && { kill "$(cat "$ICPID")" 2>/dev/null || true; rm -f "$ICPID"; }
  pkill -f 'python3 -u .*gticmp.py' 2>/dev/null || true
  sleep 0.3; ip link del "$ICTUN" 2>/dev/null || true
  GT_ICMP_ADDR="$IC_ADDR" setsid python3 -u "$GT_GTICMP" >"$ICLOG" 2>&1 </dev/null &
  echo $! > "$ICPID"
  for _ in $(seq 50); do ip link show "$ICTUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$ICTUN" >/dev/null 2>&1 || { echo "gticmp FAILED:"; cat "$ICLOG"; return 1; }

  # steer ONLY icmp at tun8, with carve-outs so tailnet + LAN pings stay native
  local d lan
  d=$(dev)
  [ -n "$d" ] || { echo "  no default interface; skipping icmp carve-outs" >&2; d=""; }
  lan=""
  [ -n "$d" ] && lan=$(ip -o -4 route show dev "$d" scope link | awk '{print $1; exit}')
  # noprefixroute (NetworkManager default for DHCP) means there is no
  # scope-link route to read; derive the subnet from the address instead.
  [ -z "$lan" ] && [ -n "$d" ] && lan=$(ip -o -4 addr show dev "$d" | awk '{print $4; exit}')
  ip route replace 100.64.0.0/10 dev tailscale0 table $IC_TABLE 2>/dev/null || true
  [ -n "$lan" ] && [ -n "$d" ] && ip route replace "$lan" dev "$d" table $IC_TABLE
  ip route replace default dev "$ICTUN" table $IC_TABLE
  ip rule del priority $IC_PRIO 2>/dev/null || true
  ip rule add ipproto icmp lookup $IC_TABLE priority $IC_PRIO

  # Reverse-path validation of an injected reply looks up the route to the reply's
  # SOURCE with no protocol set, so the `ipproto icmp` rule above cannot match it;
  # it falls through to main, finds tun9, and drops the packet. That lookup carries
  # our tun's address as its source, so key a rule on it: it matches those
  # validation lookups and nothing else, and resolves them to $ICTUN.
  ip rule del priority $((IC_PRIO - 1)) 2>/dev/null || true
  ip rule add from ${TUNADDR_IP} lookup $IC_TABLE priority $((IC_PRIO - 1))

  # Injected echo replies arrive on $ICTUN sourced from the pinged host, whose
  # route is tun9 -- strict reverse-path filtering drops them before ping sees
  # them. Exempt this one interface (raw skips rpfilter, INPUT covers a default
  # DROP policy). Scoped to $ICTUN so the rest of the firewall is untouched.
  echo 0 > /proc/sys/net/ipv4/conf/$ICTUN/rp_filter 2>/dev/null || true
  echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null || true
  echo 1 > /proc/sys/net/ipv4/conf/$ICTUN/accept_local 2>/dev/null || true
  echo 0 > /proc/sys/net/ipv4/conf/$ICTUN/log_martians 2>/dev/null || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -t raw -C PREROUTING -i "$ICTUN" -j ACCEPT 2>/dev/null || \
      iptables -t raw -I PREROUTING 1 -i "$ICTUN" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -i "$ICTUN" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT 1 -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  fi
  if command -v nft >/dev/null 2>&1 && nft list table inet nixos-fw >/dev/null 2>&1; then
    nft add table inet globaltun 2>/dev/null || true
    nft 'add chain inet globaltun pre { type filter hook prerouting priority -310 ; }' 2>/dev/null || true
    nft 'add chain inet globaltun inp { type filter hook input priority -10 ; }' 2>/dev/null || true
    nft flush chain inet globaltun pre 2>/dev/null || true
    nft flush chain inet globaltun inp 2>/dev/null || true
    nft add rule inet globaltun pre iifname "'"$ICTUN"'" accept 2>/dev/null || true
    nft add rule inet globaltun inp iifname "'"$ICTUN"'" accept 2>/dev/null || true
  fi
  echo "gticmp up: $(head -1 "$ICLOG"); icmp -> $ICTUN (table $IC_TABLE, lan=$lan direct)"
}

# Pick the relay this gateway can actually execute and make sure it is there.
#
# The gateway must need NOTHING pre-installed: a static binary with CGO off has
# no libc, no dynamic loader and no interpreter behind it, so an sshd and a
# writable /tmp are the whole contract. rsocks.py stays as a fallback for an
# architecture we do not ship a binary for, and for a /tmp mounted noexec.
#
# Echoes the command that starts the relay, or nothing if neither route works.
pick_relay(){
  local arch bin sum rpath
  arch=$(rsh1 'uname -m' 2>/dev/null | tr -d '\r')
  case $arch in
    x86_64|amd64)                 bin=$GT_RELAY_DIR/gtrelay-linux-amd64 ;;
    aarch64|arm64|armv8*|armv9*)  bin=$GT_RELAY_DIR/gtrelay-linux-arm64 ;;
    *)                            bin= ;;
  esac
  [ -n "$bin" ] && [ -f "$bin" ] || bin=

  if [ -n "$bin" ]; then
    # Content-addressed by its own hash, so the push happens once per binary
    # per gateway and never again -- it is 2MB, and the reference path to the
    # gateway runs at ~90KB/s, where re-pushing on every `up` is 25 seconds of
    # pure waste. A changed binary lands at a different name, so there is no
    # stale-cache case to reason about.
    sum=$(sha256sum "$bin" | cut -c1-16)
    rpath=/tmp/gtrelay-$sum
    # `test`, not `[`: it is also a real binary, so it survives a login shell
    # with no such builtin.
    if rsh1 "test -x $rpath" 2>/dev/null; then
      echo "  relay: $arch binary already on the gateway ($rpath)" >&2
    else
      echo "  relay: pushing $(du -h "$bin" | cut -f1) $arch binary -> $rpath" >&2
      # Via a temp name: a push interrupted halfway would otherwise leave a
      # truncated file at the cached path, which every later run would trust.
      # stdin is the binary, so the command cannot come in on it; `-c` keeps
      # the redirection out of the login shell's hands.
      if ssh -S "$CTL" "$RHOST" "/bin/sh -c 'cat > $rpath.part && chmod +x $rpath.part && mv $rpath.part $rpath'" < "$bin"; then
        :
      else
        echo "  relay: push failed, falling back to python3" >&2
        bin=
      fi
    fi
  else
    echo "  relay: no binary for gateway arch '${arch:-unknown}', falling back to python3" >&2
  fi

  # `-check` exits immediately without binding anything, so this proves the
  # gateway can EXECUTE the file -- the one thing we cannot assume -- without
  # starting a relay we would then have to clean up.
  if [ -n "$bin" ]; then
    # Redirections are done HERE, locally: a remote `2>&1` is bash/POSIX syntax
    # that csh spells differently, and only the exit status matters.
    if rsh1 "$rpath -check" >/dev/null 2>&1; then
      echo "$rpath"
      return 0
    fi
    echo "  relay: gateway will not execute $rpath (noexec /tmp? wrong arch?), falling back to python3" >&2
  fi

  # Fallback: the gateway's own python3.
  if ! rsh1 'command -v python3' >/dev/null 2>&1; then
    echo "  relay: gateway has neither an executable binary nor python3" >&2
    return 1
  fi
  ssh -S "$CTL" "$RHOST" "/bin/sh -c 'cat > /tmp/rsocks-$RPORT_SS.py'" < "$GT_RSOCKS" || return 1
  echo "python3 -u /tmp/rsocks-$RPORT_SS.py"
}

# A full tunnel makes this machine *appear* to sit wherever the gateway's egress
# does, and anything doing IP geolocation believes it. automatic-timezoned does:
# geoclue asks beacondb, beacondb has no data for the local BSSIDs and falls
# back to IP, its IP database places the gateway's Cloudflare egress in Gabon,
# and the clock moves to Africa/Libreville. Measured; see globaltun-findings.md.
#
# FREEZE, not correct. Whatever the timezone is when `up` runs was decided by
# geolocation on the REAL network, so it is already right -- including when the
# laptop has genuinely flown somewhere, which is the only case automatic
# timezone exists for. Setting a timezone here would override that.
TZUNIT=automatic-timezoned.service
TZFREEZE=/run/globaltun.tzfreeze
FREEZE_TZ=${GT_FREEZE_TZ:-1}

current_tz(){
  timedatectl show -p Timezone --value 2>/dev/null \
    || readlink -f /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' \
    || echo unknown
}

freeze_tz(){
  [ "$FREEZE_TZ" = 1 ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  # `systemctl cat` is the cheap existence test -- it exits 1 on a unit that is
  # not installed, which is the standalone-bundle-on-a-foreign-box case.
  systemctl cat "$TZUNIT" >/dev/null 2>&1 || return 0
  # Already stopped: do NOT leave a marker, or `down` would start a service the
  # person had deliberately turned off.
  systemctl is-active --quiet "$TZUNIT" || return 0
  # Marker FIRST: under the NixOS module it is also the unit's start
  # condition, so writing it before the stop leaves no window in which
  # something could start the unit again.
  : > "$TZFREEZE"
  if systemctl stop "$TZUNIT" 2>/dev/null; then
    echo "timezone frozen at $(current_tz) -- $TZUNIT stopped (egress geolocation is not where you are)"
  else
    echo "could not stop $TZUNIT; the clock may follow the gateway's apparent location" >&2
  fi
  # Freezing preserves whatever is there, including a fix that was ALREADY
  # poisoned -- by a previous tunnel, or by a rebuild that restarted the unit
  # under one. A zone other than home is either a real trip or exactly that,
  # and only the person at the keyboard knows which, so say so and leave it.
  local tz; tz=$(current_tz)
  if [ -n "${GT_TZ_HOME:-}" ] && [ "$tz" != "$GT_TZ_HOME" ]; then
    echo "  note: frozen at $tz, not your configured $GT_TZ_HOME. If you have not" >&2
    echo "  travelled, this came from a tunnelled fix: timedatectl set-timezone $GT_TZ_HOME" >&2
  fi
}

thaw_tz(){
  # Only restart what WE stopped. The marker is the whole record of that.
  [ -f "$TZFREEZE" ] || return 0
  rm -f "$TZFREEZE"
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl start "$TZUNIT" 2>/dev/null; then
    echo "timezone tracking resumed -- $TZUNIT started"
  else
    echo "could not start $TZUNIT" >&2
  fi
}

start_remote_relay(){
  local cmd
  cmd=$(pick_relay) || { echo "no usable relay on the gateway" >&2; exit 1; }
  # Unquoted heredoc so $RPORT_SS and $cmd expand HERE; \$ escapes what must
  # expand on the gateway. A quoted one would send the port through literally,
  # and the relay would silently start on its default while the -L forward
  # pointed elsewhere.
  rsh <<EOF
P=/tmp/globaltun-server-$RPORT_SS.pid
[ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P
# Migration: relays predating per-client ports used unsuffixed names and are
# invisible to the pidfile above, so they survive and hold the port, making the
# new relay fail to bind. Only the legacy names -- never another client's
# suffixed relay.
L=/tmp/globaltun-server.pid
[ -f \$L ] && kill \$(cat \$L) 2>/dev/null; rm -f \$L /tmp/rsocks.py /tmp/globaltun-server.log
: > /tmp/globaltun-server-$RPORT_SS.log
# setsid is util-linux and nohup is coreutils; a gateway we were handed may
# have either. Without one of them ssh can hold the channel open waiting on
# the child and \`up\` hangs here instead of returning.
D=\$(command -v setsid || command -v nohup || true)
RSOCKS_PORT=$RPORT_SS \$D $cmd >/tmp/globaltun-server-$RPORT_SS.log 2>&1 </dev/null &
echo \$! > \$P
sleep 2
# The relay prints its listening line only after bind() succeeded, and the log
# was truncated a moment ago -- so this is the same proof a port probe would
# give. It replaces \`exec 3<>/dev/tcp/...\`, which is a bash feature: /bin/sh
# here is dash on most gateways, where that line is a syntax error.
if grep -q 'listening on' /tmp/globaltun-server-$RPORT_SS.log 2>/dev/null; then
  echo "remote relay up: \$(head -1 /tmp/globaltun-server-$RPORT_SS.log)"
else
  echo 'remote relay FAILED:'; cat /tmp/globaltun-server-$RPORT_SS.log; exit 1
fi
EOF
}

up(){
  need_root
  SB="$GT_SINGBOX"
  [ -x "$SB" ] || { echo "missing $SB" >&2; exit 1; }

  # Before the routes move, so the last fix geoclue acted on was the real one.
  freeze_tz

  master
  echo "--- starting remote relay"
  start_remote_relay

  echo "--- starting local udp/tcp adapter"
  start_gtlocal

  echo "--- clearing any previous local sing-box / tun"
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  pkill -f 'sing-box.orig run -c .*gt-client' 2>/dev/null || true
  for _ in $(seq 30); do ip link show "$TUN" >/dev/null 2>&1 || break; sleep 0.1; done
  ip link del "$TUN" 2>/dev/null || true

  echo "--- starting local sing-box (tun)"
  setsid "$SB" run -c "$GT_SBCONF" >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDF"
  sleep 2
  kill -0 "$(cat "$PIDF")" 2>/dev/null || { echo "local sing-box died:"; tail -30 "$LOG"; exit 1; }
  for _ in $(seq 50); do ip link show "$TUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$TUN" >/dev/null 2>&1 || { echo "$TUN never appeared:"; tail -30 "$LOG"; exit 1; }

  echo "--- routing (main table, so tailscale's fwmark rule 5210 lands in the tun too)"
  # Abort before the default split if the carrier is not pinned: routing
  # 0.0.0.0/1 into a tun whose own carrier goes through it is a black hole,
  # and on a headless host nothing is then left able to undo it.
  pin_carrier || { echo "refusing to install tun routes with an unpinned carrier" >&2; exit 1; }
  ip route replace 0.0.0.0/1   dev "$TUN"
  ip route replace 128.0.0.0/1 dev "$TUN"
  tailscale_bypass
  if [ "$GT_ICMP" = 1 ]; then
    echo "--- starting icmp relay"
    start_gticmp || echo "(icmp relay unavailable -- tcp/udp unaffected)"
  fi
  if [ "${GT_TAILSCALE_DIRECT:-0}" = 1 ]; then
    echo "up -- TCP + UDP (udp-over-tcp); tailscale underlay on the physical link, LAN peers direct"
  else
    echo "up -- TCP + UDP (udp-over-tcp); tailscale underlay rides the tun, peers stay on tailscale0"
  fi
}

down(){
  need_root
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null || true; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null || true
  [ -f "$ICPID" ] && { kill "$(cat "$ICPID")" 2>/dev/null || true; rm -f "$ICPID"; }
  pkill -f 'python3 -u .*gticmp.py' 2>/dev/null || true
  ip rule del priority $IC_PRIO 2>/dev/null || true
  ip rule del priority $((IC_PRIO - 1)) 2>/dev/null || true
  ip rule del priority $TS_PRIO 2>/dev/null || true
  ip route flush table $TS_TABLE 2>/dev/null || true
  ip route flush table $IC_TABLE 2>/dev/null || true
  iptables -t raw -D PREROUTING -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -i "$ICTUN" -j ACCEPT 2>/dev/null || true
  nft delete table inet globaltun 2>/dev/null || true
  ip link del "$ICTUN" 2>/dev/null || true
  sleep 1
  have_ctl && rsh <<EOF || true
P=/tmp/globaltun-server-$RPORT_SS.pid
[ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P; true
EOF
  [ -S "$CTL" ] && { ssh -S "$CTL" -O exit "$RHOST" 2>/dev/null || true; }
  rm -f "$CTL"
  ip route del 0.0.0.0/1   2>/dev/null || true
  ip route del 128.0.0.0/1 2>/dev/null || true
  ip route del "$CARRIER/32" 2>/dev/null || true
  for p in ${GT_KEEP_DIRECT:-}; do ip route del "$p" 2>/dev/null || true; done
  ip link del "$TUN" 2>/dev/null || true
  rm -f "$STATE"
  # Last, so its first fix after this sees the real network rather than a
  # half-torn-down tunnel.
  thaw_tz
  echo "down"
}

reload_local(){   # restart only the local sing-box; keeps the ssh master + remote side
  need_root
  have_ctl || { echo "refusing: no live ssh master. Installing tun routes now would black-hole this box -- run 'up' instead." >&2; exit 1; }
  ss -ltn 2>/dev/null | grep -q ":$LPORT " || { echo "refusing: no :$LPORT forward -- run 'up' instead." >&2; exit 1; }
  SB="$GT_SINGBOX"
  start_gtlocal
  [ -f "$PIDF" ] && { kill "$(cat "$PIDF")" 2>/dev/null || true; rm -f "$PIDF"; }
  for _ in $(seq 30); do ip link show "$TUN" >/dev/null 2>&1 || break; sleep 0.1; done
  setsid "$SB" run -c "$GT_SBCONF" >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDF"
  for _ in $(seq 50); do ip link show "$TUN" >/dev/null 2>&1 && break; sleep 0.1; done
  ip link show "$TUN" >/dev/null 2>&1 || { echo "$TUN never came back:"; tail -20 "$LOG"; exit 1; }
  pin_carrier || true
  ip route replace 0.0.0.0/1   dev "$TUN"
  ip route replace 128.0.0.0/1 dev "$TUN"
  echo "local sing-box reloaded"
}






verify(){
  if ss -ltn 2>/dev/null | grep -q '127.0.0.1:12300 '; then echo "!! sshuttle still listening on :12300 -- stop it first"; exit 1; fi
  echo "=== verify $(date +%T) ==="
  python3 "$GT_VERIFY"
  echo "=== local log (last errors, icmp noise filtered)"
  grep -v 'icmp is not supported' "$LOG" 2>/dev/null | grep -E 'ERROR|FATAL|outbound|proxy' | tail -10
  echo "=== remote log tail"; have_ctl && rsh1 "tail -n 8 /tmp/globaltun-server-$RPORT_SS.log" || echo "(no master)"
}

# --- sharing the tunnel over a Wi-Fi AP on the same card -------------------
#
# AP+STA on one iwlwifi radio, which the phy advertises as
#   #{ managed } <= 1, #{ AP, ... } <= 1, total <= 3, #channels <= 1
# and which is more fragile than it looks:
#
#   * `iw ... interface add <n> type __ap` silently creates a MANAGED vif. That
#     trips #{ managed } <= 1 and link-up fails with EBUSY, which reads as the
#     driver refusing AP mode. The type must be set AFTER creation, while down.
#   * NetworkManager cannot drive this at all. It does AP mode by asking
#     wpa_supplicant to flip a *managed* interface, which the same limit
#     forbids; hand it a ready-made AP vif and the supplicant will not grab it.
#     hostapd directly is the only route.
#   * #channels <= 1 means the AP must sit on the STA's CURRENT channel -- and
#     must MOVE with it. The upstream network moves its clients by channel
#     switch announcement (CSA), here every 5-10 minutes. A station whose AP
#     stays put cannot finalize the switch ("channel context reservation cannot
#     be finalized because some interfaces aren't switching", err=-16) and is
#     disconnected; while hostapd holds the old channel it can rejoin only an
#     upstream AP on that same channel. On 2026-10-10 that took victus-15 off the
#     network for half an hour, tunnel and all. share_watch follows the station.
SHARE_CONF=/run/globaltun-ap.conf
SHARE_PID=/run/globaltun-hostapd.pid
SHARE_DNS_PID=/run/globaltun-dnsmasq.pid
SHARE_WATCH_PID=/run/globaltun-share-watch.pid
SHARE_WATCH_LOG=/run/globaltun-share-watch.log
SHARE_CTRL=/run/globaltun-hostapd

# Regulatory flags for one frequency, from the card's own table. Prints the
# blocking reason and exits 0 when the channel cannot host an AP; exits 1 when
# it is clear.
#
# "Radar detection" is DFS: hostapd will not initiate radiation on radar
# spectrum, and a station parked there cannot be joined by an AP vif because
# this card's interface combinations cap AP+station at `#channels <= 1` -- one
# radio, one frequency. "No IR" blocks initiating radiation outright.
chan_restricted(){
  local freq=$1 phy
  phy=phy$(iw dev "$GT_SHARE_STA" info 2>/dev/null | awk '/wiphy/{print $2}')
  iw phy "$phy" channels 2>/dev/null | awk -v f="$freq" '
    $0 ~ "\\* " f " MHz"                       { inblk=1; next }
    inblk && /^[[:space:]]*\* [0-9]+ MHz/       { inblk=0 }
    inblk && (/Radar detection/ || /No IR/)     { gsub(/^[ \t]+/,""); print; found=1 }
    END { exit !found }
  '
}

# Channels the upstream SSID is actually on AND that can host an AP -- i.e. the
# ones worth roaming to. Advice without this is "pick a different channel",
# which is not advice.
suggest_channels(){
  command -v nmcli >/dev/null 2>&1 || return 0
  local ssid
  ssid=$(iw dev "$GT_SHARE_STA" info 2>/dev/null | sed -n 's/^[[:space:]]*ssid //p')
  [ -n "$ssid" ] || return 0
  nmcli -t -f SSID,CHAN,FREQ,SIGNAL dev wifi list 2>/dev/null \
    | awk -F: -v s="$ssid" '$1==s { split($3, a, " "); print $2, a[1], $4 }' \
    | while read -r c f sig; do
        chan_restricted "$f" >/dev/null 2>&1 \
          || printf '    channel %-4s %-5s MHz   signal %s\n' "$c" "$f" "$sig"
      done | sort -u -k2 -n | head -8
}

# hostapd's config for channel $1 with passphrase $2 -- written at `share` and
# again whenever share_watch has to restart the AP on a new channel.
share_conf(){
  local ch=$1 psk=$2 hwmode vht
  # hw_mode follows the channel. It was hardcoded to `a`, which fails on any
  # 2.4GHz channel with "Configured channel (11) ... not found from the channel
  # list of the current mode (2) IEEE 802.11a" -- the same shape of error as a
  # DFS rejection, from a completely different cause. VHT is 5GHz-only, so it
  # has to follow too.
  if [ "$ch" -le 14 ]; then hwmode=g; vht=0; else hwmode=a; vht=1; fi

  ( umask 077; cat > "$SHARE_CONF" <<CONF
interface=$GT_SHARE_AP
driver=nl80211
ssid=$GT_SHARE_SSID
country_code=$GT_SHARE_COUNTRY
hw_mode=$hwmode
channel=$ch
ieee80211n=1
ieee80211ac=$vht
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$psk
ctrl_interface=$SHARE_CTRL
CONF
  )
}

share_up(){
  need_root
  [ "${GT_SHARE:-0}" = 1 ] || { echo "sharing is not enabled (my.globaltun.share.enable)" >&2; exit 1; }
  is_up || { echo "refusing: the tunnel is not up, so there is nothing to share" >&2; exit 1; }

  local psk ch
  psk=$(cat "$GT_SHARE_PSK_FILE" 2>/dev/null) || { echo "cannot read $GT_SHARE_PSK_FILE" >&2; exit 1; }
  [ ${#psk} -ge 8 ] || { echo "the PSK in $GT_SHARE_PSK_FILE must be at least 8 characters" >&2; exit 1; }

  ip link show "$GT_SHARE_AP" >/dev/null 2>&1 || iw dev "$GT_SHARE_STA" interface add "$GT_SHARE_AP" type __ap
  # Belt and braces alongside networking.networkmanager.unmanaged: NM matches
  # saved profiles against any wifi device, and on a card allowing two managed
  # interfaces it will autoconnect this one to the upstream network and move
  # the default route onto it.
  command -v nmcli >/dev/null && nmcli dev set "$GT_SHARE_AP" managed no >/dev/null 2>&1 || true
  if [ "$(iw dev "$GT_SHARE_AP" info | awk '/type/{print $2}')" != AP ]; then
    ip link set "$GT_SHARE_AP" down
    iw dev "$GT_SHARE_AP" set type __ap
  fi
  ip link set "$GT_SHARE_AP" up

  local freq reason
  ch=$(iw dev "$GT_SHARE_STA" info | awk '/channel/{print $2}')
  freq=$(iw dev "$GT_SHARE_STA" info | sed -n 's/.*channel [0-9]* (\([0-9]*\) MHz.*/\1/p')
  [ -n "$ch" ] || { echo "$GT_SHARE_STA is not associated; the AP needs its channel" >&2; exit 1; }

  # The AP has to use the station's channel, so a station on radar spectrum
  # makes an AP impossible -- and hostapd reports that as eight lines of
  # nl80211 detail that never say "DFS". Fail here with the one fact that
  # matters, and with somewhere to go.
  if reason=$(chan_restricted "$freq"); then
    {
      echo "cannot host an AP on channel $ch ($freq MHz): $reason"
      echo
      echo "This card allows an AP alongside a station only on ONE channel"
      echo "(#channels <= 1 in its interface combinations), so the AP must use"
      echo "$GT_SHARE_STA's channel -- and that channel is restricted spectrum."
      echo "The card is capable; this channel is not."
      echo
      echo "Move $GT_SHARE_STA to a channel that can host an AP. On the network it is"
      echo "associated to, these are reachable and unrestricted:"
      suggest_channels
      echo
      echo "To stay off radar spectrum for good, pin the profile to 2.4GHz, where"
      echo "no channel is DFS -- roaming still works within the band:"
      echo "  nmcli con modify <profile> 802-11-wireless.band bg && nmcli con up <profile>"
    } >&2
    exit 1
  fi

  share_conf "$ch" "$psk"

  ip addr replace "$GT_SHARE_ADDR" dev "$GT_SHARE_AP"

  # Clients must reach THIS HOST (DHCP :67, DNS :53) before they can route
  # through it. Without this the firewall drops those silently: hostapd
  # completes the WPA handshake, the client shows "connected", and dnsmasq
  # never logs a DISCOVER because it never receives one.
  iptables -C INPUT -i "$GT_SHARE_AP" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i "$GT_SHARE_AP" -j ACCEPT
  iptables -C FORWARD -i "$GT_SHARE_AP" -o "$TUN" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$GT_SHARE_AP" -o "$TUN" -j ACCEPT
  iptables -C FORWARD -i "$TUN" -o "$GT_SHARE_AP" -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i "$TUN" -o "$GT_SHARE_AP" -j ACCEPT
  # No NAT: sing-box terminates each flow and re-originates it, then writes the
  # reply back to the tun addressed to the original client. Masquerading would
  # only add work.
  echo 1 > /proc/sys/net/ipv4/ip_forward

  hostapd -B -P "$SHARE_PID" "$SHARE_CONF"
  dnsmasq --interface="$GT_SHARE_AP" --bind-interfaces \
          --dhcp-range="$GT_SHARE_DHCP" \
          --dhcp-option=3,"${GT_SHARE_ADDR%%/*}" --dhcp-option=6,"$GT_DNS" \
          --no-resolv --no-hosts --pid-file="$SHARE_DNS_PID"
  share_watch_start
  echo "sharing on $GT_SHARE_SSID, channel $ch (following $GT_SHARE_STA), clients get $GT_SHARE_DHCP"
}

# --- keeping the AP on the station's channel ---------------------------------
# Kernel nl80211 events via `iw event`, not wpa_supplicant: NetworkManager runs
# the supplicant on D-Bus only, with no control socket for wpa_cli to read.
#
#   channel switch started (freq=F)  the upstream AP announced a CSA. Ask hostapd
#                                    to switch too (its own CSA to its clients),
#                                    so both interfaces leave together and the
#                                    station's reservation can be finalized.
#   disconnected                     a roam, or a switch that failed anyway. If
#                                    the station has not rejoined within a few
#                                    seconds, stop hostapd: holding the channel
#                                    is what keeps it from rejoining elsewhere.
#   connected / roamed               restart the AP on the station's channel if
#                                    it stopped or ended up on another one.
share_log(){ echo "$(date '+%F %T') $*"; }
share_ap_running(){ [ -f "$SHARE_PID" ] && kill -0 "$(cat "$SHARE_PID")" 2>/dev/null; }
share_ap_stop(){
  share_ap_running && kill "$(cat "$SHARE_PID")" 2>/dev/null
  rm -f "$SHARE_PID"
}
# Restart the AP on whatever channel the station is on now; a station that is
# not associated, or sits on restricted spectrum, leaves it stopped.
share_ap_follow(){
  local ch freq ap_ch psk reason
  ch=$(iw dev "$GT_SHARE_STA" info 2>/dev/null | awk '/channel/{print $2}')
  freq=$(iw dev "$GT_SHARE_STA" info 2>/dev/null | sed -n 's/.*channel [0-9]* (\([0-9]*\) MHz.*/\1/p')
  [ -n "$ch" ] || { share_ap_stop; share_log "station not associated; AP stopped until it is"; return; }
  ap_ch=$(iw dev "$GT_SHARE_AP" info 2>/dev/null | awk '/channel/{print $2}')
  share_ap_running && [ "$ap_ch" = "$ch" ] && return
  if reason=$(chan_restricted "$freq"); then
    share_ap_stop; share_log "station on channel $ch ($reason); AP stays down"; return
  fi
  psk=$(cat "$GT_SHARE_PSK_FILE" 2>/dev/null) || { share_log "cannot read $GT_SHARE_PSK_FILE"; return; }
  share_ap_stop
  share_conf "$ch" "$psk"
  if hostapd -B -P "$SHARE_PID" "$SHARE_CONF" >/dev/null; then
    share_log "AP restarted on channel $ch, following $GT_SHARE_STA"
  else
    share_log "hostapd failed to start on channel $ch"
  fi
}
share_watch(){
  local line freq pending=""
  share_log "watching $GT_SHARE_STA for channel switches and roams"
  iw event | while IFS= read -r line; do
    case $line in "$GT_SHARE_STA "*|"$GT_SHARE_STA:"*) ;; *) continue ;; esac
    case $line in
      *"channel switch started"*)
        # the first standalone freq= -- not center_freq1=, which a greedy match caught
        freq=$(printf '%s\n' "$line" | grep -oE '(^|[ (])freq=[0-9]+' | head -n1 | grep -oE '[0-9]+$')
        [ -n "$freq" ] || { share_log "CSA without a frequency: $line"; continue; }
        if share_ap_running && hostapd_cli -p "$SHARE_CTRL" -i "$GT_SHARE_AP" chan_switch 1 "$freq" ht >/dev/null 2>&1; then
          share_log "upstream switching to $freq MHz; AP switching with it"
        else
          # Cannot follow in place: get out of the way so the station can switch.
          share_ap_stop
          share_log "upstream switching to $freq MHz; AP could not switch, stopped until the station settles"
        fi ;;
      *disconnected*)
        # A failed switch or a roam. Give the supplicant a moment on its own
        # first -- it often rejoins on the same channel -- then clear the way.
        ( sleep 4
          iw dev "$GT_SHARE_STA" link 2>/dev/null | grep -q '^Connected' && exit 0
          share_ap_stop
          share_log "station still disconnected; AP stopped so it can rejoin on any channel" ) & ;;
      *connected*|*roamed*|*"channel switch"*)
        # joined or roamed (maybe elsewhere), or a switch finished: put the AP
        # where the station is. (Formats: iw event.c -- "connected to <bssid>",
        # "roamed to <bssid>", "channel switch (count=N) freq=F ...".)
        sleep 1; share_ap_follow ;;
    esac
  done
}
share_watch_start(){
  [ -f "$SHARE_WATCH_PID" ] && kill "$(cat "$SHARE_WATCH_PID")" 2>/dev/null
  setsid "$0" share-watch </dev/null >>"$SHARE_WATCH_LOG" 2>&1 &
  echo $! > "$SHARE_WATCH_PID"
}
share_watch_stop(){
  # setsid made the watcher a process-group leader; take its `iw event` and
  # any pending timer with it
  [ -f "$SHARE_WATCH_PID" ] && kill -- -"$(cat "$SHARE_WATCH_PID")" 2>/dev/null
  rm -f "$SHARE_WATCH_PID"
}

share_down(){
  need_root
  share_watch_stop
  [ -f "$SHARE_DNS_PID" ] && { kill "$(cat "$SHARE_DNS_PID")" 2>/dev/null || true; rm -f "$SHARE_DNS_PID"; }
  [ -f "$SHARE_PID" ]     && { kill "$(cat "$SHARE_PID")" 2>/dev/null || true; rm -f "$SHARE_PID"; }
  rm -f "$SHARE_CONF"
  iptables -D INPUT -i "$GT_SHARE_AP" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$GT_SHARE_AP" -o "$TUN" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$TUN" -o "$GT_SHARE_AP" -j ACCEPT 2>/dev/null || true
  ip link set "$GT_SHARE_AP" down 2>/dev/null || true
  echo "sharing stopped"
}

share_status(){
  echo "--- ap";       ip -br addr show "$GT_SHARE_AP" 2>/dev/null || echo "  no $GT_SHARE_AP"
  iw dev "$GT_SHARE_AP" info 2>/dev/null | grep -E 'type|channel|ssid' | sed 's/^/  /'
  echo "--- hostapd";  pgrep -a hostapd >/dev/null && echo "  running" || echo "  not running"
  echo "--- dnsmasq";  [ -f "$SHARE_DNS_PID" ] && echo "  running" || echo "  not running"
  echo "--- clients";  iw dev "$GT_SHARE_AP" station dump 2>/dev/null | grep -c '^Station' | sed 's/^/  associated: /'
  echo "--- leases";   ip neigh show dev "$GT_SHARE_AP" 2>/dev/null | sed 's/^/  /' || echo "  none with an IP"
}


# Quiet predicate for automation: 0 = carrying traffic, 1 = not.
is_up(){ have_ctl && ip link show "$TUN" >/dev/null 2>&1; }

status(){
  echo "--- ssh master"; have_ctl && echo "connected" || echo "no control socket"
  echo "--- forward";    ss -ltn 2>/dev/null | grep ":$LPORT" || echo "no :$LPORT listener"
  echo "--- gticmp";     ip -br addr show "$ICTUN" 2>/dev/null || echo "  no $ICTUN"
  echo "--- icmp rule";  ip rule show | grep -E "$IC_PRIO" || echo "  no icmp rule"
  echo "--- gtlocal";     ss -ltn 2>/dev/null | grep ":$LOCAL_PORT " || echo "  not listening"
  echo "--- local sing-box"; [ -f "$PIDF" ] && ps -o pid,etime,cmd -p "$(cat "$PIDF")" 2>/dev/null || echo "not running"
  echo "--- tun";        ip -br addr show "$TUN" 2>/dev/null || echo "no $TUN"
  echo "--- routes";     ip route show | grep -E '^(0\.0\.0\.0/1|128\.0\.0\.0/1|default|'"$CARRIER"')' || true
  echo "--- timezone";   if [ -f "$TZFREEZE" ]; then echo "  $(current_tz) (frozen by globaltun)"
                      else echo "  $(current_tz)$(command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$TZUNIT" 2>/dev/null && echo ' (tracking geolocation -- will follow the gateway)')"; fi
  echo "--- tailscale";  tailscale status --peers=false 2>&1 | grep -E 'Health|DNS|^[0-9]' | head -3
  echo "--- egress v4";  curl -s --max-time 10 https://ifconfig.me 2>&1; echo
  echo "--- udp test";   command -v dig >/dev/null && dig +short +time=5 @8.8.8.8 example.com 2>&1 || echo "(no dig)"
  echo "--- log tail";   tail -5 "$LOG" 2>/dev/null
}

# `hop N [cmd...]`: an ssh session on hop N (1-based, as in gt-hop-N), through
# every hop before it and with its own credentials. For debugging a chain one
# link at a time: `globaltun hop 2 true` failing while `hop 1 true` works puts
# the fault between the two.
hop_ssh(){
  local n=${1:-} i
  case $n in ''|*[!0-9]*) echo "usage: hop N [cmd...]" >&2; exit 2 ;; esac
  shift; i=$((n - 1))
  [ "$i" -ge 0 ] && [ "$i" -lt ${#H_KIND[@]} ] || { echo "no hop $n (have ${#H_KIND[@]})" >&2; exit 2; }
  [ "${H_KIND[$i]}" = ssh ] || { echo "hop $n is a ${H_KIND[$i]} proxy, not an ssh host" >&2; exit 2; }
  local pre=()
  [ "${H_AUTH[$i]}" = password ] && pre=(env "GT_PASSFILE=${H_SECRET[$i]}" "SSH_ASKPASS=$ASKPASS" SSH_ASKPASS_REQUIRE=force)
  exec "${pre[@]}" "$SSH_BIN" -F "$GT_SSHCFG" "gt-hop-$n" "$@"
}

# Walk the whole chain to the gateway and read its sshd banner. Exercises every
# hop, of every kind, with the credentials `up` will use -- without creating a
# tun or touching a route, so it is safe to run on a host that is mid-outage.
probe(){
  local th=${RHOST##*@} cmd out err pid
  cmd=$(reach_cmd "$th:$RPORT" ${#H_KIND[@]}) || exit 1
  local fifo
  out=$(mktemp); err=$(mktemp); fifo=$(mktemp -u)
  if [ -z "$cmd" ]; then
    timeout 30 bash -c "exec 3<>/dev/tcp/$th/$RPORT && head -c 4 <&3" >"$out" 2>"$err" &
    pid=$!
  else
    # stdin must stay OPEN: on EOF, ssh -W tears the channel down before the
    # banner arrives. Held by a fifo this function owns and closes, not by a
    # `<(sleep N)`: a process substitution inherits the caller's stderr, so
    # anything capturing probe's output -- `$(globaltun probe)`, a pipe --
    # waited the full N seconds after the answer was already in. Measured: 90s.
    mkfifo -m 600 "$fifo"
    bash -c "exec $cmd" <"$fifo" >"$out" 2>"$err" &
    pid=$!
    exec 7>"$fifo"
  fi
  for _ in $(seq 360); do
    [ "$(head -c 4 "$out")" = SSH- ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  # Both tolerated: on a FAILED chain the process is already gone, and under
  # set -e a failing `kill` would end the script right here -- silently, one
  # line before it prints the error it captured, which is the only part of a
  # failure anyone needs.
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -p "$fifo" ]; then exec 7>&-; rm -f "$fifo"; fi
  if [ "$(head -c 4 "$out")" = SSH- ]; then
    echo "gateway $th:$RPORT reachable through ${#H_KIND[@]} hop(s): $(head -1 "$out" | tr -d '\r')"
    rm -f "$out" "$err"; return 0
  fi
  echo "gateway $th:$RPORT NOT reachable through ${#H_KIND[@]} hop(s)." >&2
  [ -s "$err" ] && sed 's/^/  /' "$err" >&2
  rm -f "$out" "$err"; return 1
}

case "${1:-}" in
  up)      up ;;
  down)    down ;;
  status)  status ;;
  verify)  verify ;;
  reload)  reload_local ;;
  reicmp)  need_root; start_gticmp ;;
  is-up)   need_root; is_up ;;
  share)      share_up ;;
  unshare)    share_down ;;
  share-status) share_status ;;
  share-watch)  need_root; share_watch ;;
  # Prints the path to the generated hop chain, or nothing when there are no
  # hops. Reading it explains the chain; for USING it, prefer `hop`, which also
  # supplies a password hop's askpass that a bare `ssh -F` would lack.
  ssh-config) [ ${#H_KIND[@]} -gt 0 ] && echo "$GT_SSHCFG" || true ;;
  hop)     shift; hop_ssh "$@" ;;
  probe)   probe ;;
  *) echo "usage: $0 {up|down|status|verify|reload|reicmp|is-up|share|unshare|share-status|ssh-config|hop N [cmd]|probe}" >&2; exit 2 ;;
esac
