#!/usr/bin/env bash
# globaltun-termux -- the unprivileged half of globaltun, for an UNROOTED
# Android client. Run in Termux (not proot-distro).
#
# It deliberately does no routing and creates no tun: neither is possible
# without CAP_NET_ADMIN. On Android the sanctioned equivalent is VpnService,
# which only an app can use -- so sing-box's Android app owns the tun and the
# routes, and this script provides everything below it:
#
#   sing-box app (VpnService tun)
#        |  socks5 127.0.0.1:$LOCAL_PORT
#        v
#   gtlocal.py ......... UDP-ASSOCIATE handled here, over loopback
#        |  one TCP stream
#        v
#   ssh -L 127.0.0.1:$LPORT -> gateway 127.0.0.1:$RPORT_SS
#        v
#   rsocks.py on the gateway ... real connect()/sendto()
#
# The app config MUST exclude this app from the VPN
# (`"exclude_package": ["com.termux"]`), or ssh's own carrier is captured by
# the tunnel it carries and nothing can connect. That is the same failure as an
# unpinned VPN underlay on a Linux host, expressed through Android's per-app
# list instead of a route.
#
# ICMP is not carried: VpnService grants one tun to one app, so there is
# nowhere to put the second tun `gticmp.py` needs. The app answers pings itself.
#
# Usage: ./globaltun-termux.sh {up|down|status}
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/globaltun.env" ]; then
  . "$HERE/globaltun.env"
elif [ -f "$HERE/globaltun.env.example" ]; then
  echo "no globaltun.env beside $0 -- start from the template:" >&2
  echo "  cp $HERE/globaltun.env.example $HERE/globaltun.env && \$EDITOR $HERE/globaltun.env" >&2
  exit 1
fi

RHOST=${GT_RHOST:?set GT_RHOST, e.g. root@gateway}
KEY=${GT_KEY:?set GT_KEY, path to the ssh private key}
RPORT=${GT_RPORT:-8022}
# Hops between the phone and the gateway, nearest first, space- or
# comma-separated, each `[user@]host[:port]`. Empty means the phone dials the
# gateway itself. GT_JUMP (singular) is still read for older globaltun.env
# files on phones already set up.
JUMPS=${GT_JUMPS:-${GT_JUMP:-}}
JUMP_TIMEOUT=${GT_JUMP_TIMEOUT:-120}
[ "$JUMPS" = "-" ] && JUMPS=""
JUMP_LIST=()
for _j in ${JUMPS//,/ }; do JUMP_LIST+=("$_j"); done
RPORT_SS=${GT_REMOTE_SOCKS_PORT:?set GT_REMOTE_SOCKS_PORT -- must be unique per client}
LPORT=${GT_LPORT:-11080}
LOCAL_PORT=${GT_LOCAL_PORT:-1081}
# The relays are NOT duplicated here -- one copy, in the feature root. Look
# beside this script first (a flat bundle copied to the phone), then one level
# up (running straight from a checkout).
for d in "$HERE" "$HERE/.."; do
  [ -z "${GT_RSOCKS:-}"  ] && [ -f "$d/rsocks.py"  ] && GT_RSOCKS=$d/rsocks.py
  [ -z "${GT_GTLOCAL:-}" ] && [ -f "$d/gtlocal.py" ] && GT_GTLOCAL=$d/gtlocal.py
  # Static relay binaries, if this bundle carries them. Optional: without them
  # the gateway needs its own python3, which is exactly the prerequisite they
  # exist to remove.
  [ -z "${GT_RELAY_DIR:-}" ] && { [ -f "$d/gtrelay-linux-amd64" ] || [ -f "$d/gtrelay-linux-arm64" ]; } && GT_RELAY_DIR=$d
done
GT_RELAY_DIR=${GT_RELAY_DIR:-}
[ -n "${GT_RSOCKS:-}" ]  || { echo "rsocks.py not found beside or above $HERE" >&2; exit 1; }
[ -n "${GT_GTLOCAL:-}" ] || { echo "gtlocal.py not found beside or above $HERE" >&2; exit 1; }

# Termux has no /run; keep runtime state where the app can actually write.
RT=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
CTL=$RT/globaltun.ctl
GLPID=$RT/globaltun-gtlocal.pid
GLLOG=$RT/globaltun-gtlocal.log

SSHOPTS=(-i "$KEY" -p "$RPORT"
         -o StrictHostKeyChecking=accept-new
         -o ServerAliveInterval=30 -o ServerAliveCountMax=10
         -o ExitOnForwardFailure=yes)
# One Host block per hop, chained with ProxyJump, rather than a bare `-J`:
# ssh(1) applies -i to the DESTINATION only, so under `-J` every hop falls back
# to password auth and parks unauthenticated slots on its sshd until
# MaxStartups starts refusing new connections outright.
SSHCFG=$RT/globaltun.ssh_config
if [ ${#JUMP_LIST[@]} -gt 0 ]; then
  : > "$SSHCFG"; chmod 600 "$SSHCFG"
  _prev=""; _i=0
  for _e in "${JUMP_LIST[@]}"; do
    _i=$((_i + 1)); _n=gt-hop-$_i
    _u=""; _h=$_e; _p=22
    case $_h in *@*) _u=${_h%%@*}; _h=${_h#*@} ;; esac
    case $_h in *:*) _p=${_h##*:};  _h=${_h%%:*} ;; esac
    {
      echo "Host $_n"
      echo "  HostName $_h"
      [ -n "$_u" ] && echo "  User $_u"
      echo "  Port $_p"
      echo "  IdentityFile $KEY"
      echo "  IdentitiesOnly yes"
      echo "  StrictHostKeyChecking accept-new"
      echo "  ConnectTimeout $JUMP_TIMEOUT"
      [ -n "$_prev" ] && echo "  ProxyJump $_prev"
    } >> "$SSHCFG"
    _prev=$_n
  done
  SSHOPTS+=(-F "$SSHCFG" -o ProxyJump="$_prev")
fi

have_ctl(){ [ -S "$CTL" ] && ssh -S "$CTL" -O check "$RHOST" >/dev/null 2>&1; }

# Run a script on the gateway in a POSIX shell, read from stdin. `ssh host
# "script"` hands the string to the gateway user's LOGIN shell -- fish, csh,
# whatever they chose -- where `P=/tmp/x` is a syntax error and the block dies
# on its first line. This way the login shell gets one word to exec.
rsh(){ ssh -S "$CTL" "$RHOST" /bin/sh; }
# Same for a one-liner, where stdin is needed for something else.
rsh1(){ ssh -S "$CTL" "$RHOST" "/bin/sh -c '$1'"; }

# Termux ships no iproute2, so `ss` is absent -- and where it exists (proot on
# the gateway) Android blocks the netlink it needs, so it reports nothing and
# looks like "not listening". bash's /dev/tcp asks the only question that
# matters and needs neither.
port_open(){ (exec 3<>/dev/tcp/127.0.0.1/"$1") 2>/dev/null; }

up(){
  have_ctl || {
    port_open "$LPORT" && { echo "port $LPORT already in use -- run 'down' first" >&2; exit 1; }
    rm -f "$CTL"
    local n t err; n=0; err=$(mktemp)
    for t in ${GT_TIMEOUTS:-300 600 900}; do
      n=$((n+1))
      echo "master attempt $n (ConnectTimeout=${t}s; proot login on the gateway is slow)..." >&2
      ssh -M -S "$CTL" -f -N -o ConnectTimeout="$t" \
          -L "127.0.0.1:$LPORT:127.0.0.1:$RPORT_SS" "${SSHOPTS[@]}" "$RHOST" 2>"$err" \
        && have_ctl && { rm -f "$err"; break; }
      echo "  failed: $(tr '\n' ' ' <"$err" | sed 's/  */ /g')" >&2
      rm -f "$CTL"; [ $n -lt 3 ] && sleep $(( n * ${GT_RETRY_DELAY:-20} ))
    done
    rm -f "$err"
    have_ctl || { echo "could not establish the carrier to $RHOST" >&2; exit 1; }
  }
  echo "carrier up (-L 127.0.0.1:$LPORT -> gateway 127.0.0.1:$RPORT_SS)"

  # Prefer a static binary for the gateway's architecture -- it needs no
  # interpreter, no libc and no loader there -- and fall back to pushing the
  # Python relay only if this bundle has no binary the gateway can run.
  RELAY="python3 -u /tmp/rsocks-$RPORT_SS.py"
  if [ -n "$GT_RELAY_DIR" ]; then
    _arch=$(rsh1 'uname -m' 2>/dev/null | tr -d '\r')
    case $_arch in
      x86_64|amd64)                _bin=$GT_RELAY_DIR/gtrelay-linux-amd64 ;;
      aarch64|arm64|armv8*|armv9*) _bin=$GT_RELAY_DIR/gtrelay-linux-arm64 ;;
      *)                           _bin= ;;
    esac
    if [ -n "$_bin" ] && [ -f "$_bin" ]; then
      # Content-addressed, so the 2MB push happens once per gateway.
      _sum=$(sha256sum "$_bin" | cut -c1-16); _rp=/tmp/gtrelay-$_sum
      # `test`, not `[`: also a real binary, so it survives a login shell with
      # no such builtin. Redirections stay local -- a remote `2>&1` is syntax
      # csh spells differently, and only the exit status matters.
      rsh1 "test -x $_rp" 2>/dev/null \
        || ssh -S "$CTL" "$RHOST" "/bin/sh -c 'cat > $_rp.part && chmod +x $_rp.part && mv $_rp.part $_rp'" < "$_bin"
      if rsh1 "$_rp -check" >/dev/null 2>&1; then
        RELAY=$_rp
        echo "relay: static $_arch binary at $_rp"
      else
        echo "relay: gateway will not execute $_rp, falling back to python3" >&2
      fi
    fi
  fi
  [ "$RELAY" = "python3 -u /tmp/rsocks-$RPORT_SS.py" ] \
    && ssh -S "$CTL" "$RHOST" "/bin/sh -c 'cat > /tmp/rsocks-$RPORT_SS.py'" < "$GT_RSOCKS"
  rsh <<EOF || exit 1
P=/tmp/globaltun-server-$RPORT_SS.pid
[ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P
: > /tmp/globaltun-server-$RPORT_SS.log
D=\$(command -v setsid || command -v nohup || true)
RSOCKS_PORT=$RPORT_SS \$D $RELAY >/tmp/globaltun-server-$RPORT_SS.log 2>&1 </dev/null &
echo \$! > \$P
sleep 2
# The relay prints its listening line only after bind() succeeded, and the log
# was truncated a moment ago. Replaces \`exec 3<>/dev/tcp/...\`, which is a
# bash feature -- /bin/sh here is dash on most gateways.
if grep -q 'listening on' /tmp/globaltun-server-$RPORT_SS.log 2>/dev/null; then
  echo "remote relay up: \$(head -1 /tmp/globaltun-server-$RPORT_SS.log)"
else
  echo 'remote relay FAILED:'; cat /tmp/globaltun-server-$RPORT_SS.log; exit 1
fi
EOF

  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null; rm -f "$GLPID"; }
  # setsid is util-linux, absent from a default Termux; nohup is in coreutils.
  DETACH=$(command -v setsid || command -v nohup)
  GT_LOCAL_PORT=$LOCAL_PORT GT_REMOTE_PORT=$LPORT \
    $DETACH python3 -u "$GT_GTLOCAL" >"$GLLOG" 2>&1 </dev/null &
  echo $! > "$GLPID"
  sleep 1
  port_open "$LOCAL_PORT" \
    && echo "gtlocal up: $(head -1 "$GLLOG")" \
    || { echo "gtlocal FAILED (nothing listening on $LOCAL_PORT):"; cat "$GLLOG"; exit 1; }

  cat <<EOT

Termux itself is excluded from the VPN, so its own traffic does NOT go through
the tunnel. For pkg/apt, install apt-proxy.conf.example; for anything else in
this shell:
  export ALL_PROXY=socks5h://127.0.0.1:$LOCAL_PORT
(ssh ignores ALL_PROXY, so the carrier cannot loop through itself.)

Now start the sing-box app with sing-box-android.json. Its socks outbound must
point at 127.0.0.1:$LOCAL_PORT, and the tun inbound must carry
  "exclude_package": ["com.termux"]
or ssh's carrier is captured by the tunnel it carries.
EOT
}

down(){
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null
  have_ctl && rsh <<EOF
P=/tmp/globaltun-server-$RPORT_SS.pid
[ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P; true
EOF
  [ -S "$CTL" ] && ssh -S "$CTL" -O exit "$RHOST" 2>/dev/null
  rm -f "$CTL"
  echo "down (stop the VPN in the sing-box app too)"
}

status(){
  echo "--- carrier";  have_ctl && echo "  connected" || echo "  no control socket"
  echo "--- forward";  port_open "$LPORT"      && echo "  :$LPORT open" || echo "  no :$LPORT listener"
  echo "--- gtlocal";  port_open "$LOCAL_PORT" && echo "  :$LOCAL_PORT open" || echo "  not listening"
  # THROUGH the proxy, not around it. Unlike the Linux hosts, `up` installs no
  # routes here -- the app owns those -- so a plain curl would report the
  # phone's own (absent) internet and look like a broken tunnel.
  echo "--- egress via gtlocal"
  curl -s --socks5 127.0.0.1:"$LOCAL_PORT" --max-time 30 https://1.1.1.1/cdn-cgi/trace 2>/dev/null \
    | grep -E '^(ip|loc)=' | sed 's/^/  /' \
    || echo "  FAILED -- the chain gtlocal -> ssh -L -> gateway relay is broken"
  echo "--- gtlocal log"; tail -3 "$GLLOG" 2>/dev/null
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 2 ;;
esac
