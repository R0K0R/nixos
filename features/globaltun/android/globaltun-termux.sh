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
[ -f "$HERE/globaltun.env" ] && . "$HERE/globaltun.env"

RHOST=${GT_RHOST:?set GT_RHOST, e.g. root@gateway}
KEY=${GT_KEY:?set GT_KEY, path to the ssh private key}
RPORT=${GT_RPORT:-8022}
JUMP=${GT_JUMP:-}
JUMP_TIMEOUT=${GT_JUMP_TIMEOUT:-120}
RPORT_SS=${GT_REMOTE_SOCKS_PORT:?set GT_REMOTE_SOCKS_PORT -- must be unique per client}
LPORT=${GT_LPORT:-11080}
LOCAL_PORT=${GT_LOCAL_PORT:-1081}
# The relays are NOT duplicated here -- one copy, in the feature root. Look
# beside this script first (a flat bundle copied to the phone), then one level
# up (running straight from a checkout).
for d in "$HERE" "$HERE/.."; do
  [ -z "${GT_RSOCKS:-}"  ] && [ -f "$d/rsocks.py"  ] && GT_RSOCKS=$d/rsocks.py
  [ -z "${GT_GTLOCAL:-}" ] && [ -f "$d/gtlocal.py" ] && GT_GTLOCAL=$d/gtlocal.py
done
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
[ -n "$JUMP" ] && SSHOPTS+=(-o ProxyCommand="ssh -i $KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=$JUMP_TIMEOUT -W %h:%p $JUMP")

have_ctl(){ [ -S "$CTL" ] && ssh -S "$CTL" -O check "$RHOST" >/dev/null 2>&1; }

up(){
  have_ctl || {
    ss -ltn 2>/dev/null | grep -q ":$LPORT " && { echo "port $LPORT already in use -- run 'down' first" >&2; exit 1; }
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

  ssh -S "$CTL" "$RHOST" "cat > /tmp/rsocks-$RPORT_SS.py" < "$GT_RSOCKS"
  ssh -S "$CTL" "$RHOST" "
    P=/tmp/globaltun-server-$RPORT_SS.pid
    [ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P
    : > /tmp/globaltun-server-$RPORT_SS.log
    RSOCKS_PORT=$RPORT_SS setsid python3 -u /tmp/rsocks-$RPORT_SS.py >/tmp/globaltun-server-$RPORT_SS.log 2>&1 </dev/null &
    echo \$! > \$P
    sleep 2
    if (exec 3<>/dev/tcp/127.0.0.1/$RPORT_SS) 2>/dev/null; then
      echo \"remote relay up: \$(head -1 /tmp/globaltun-server-$RPORT_SS.log)\"
    else
      echo 'remote relay FAILED:'; cat /tmp/globaltun-server-$RPORT_SS.log; exit 1
    fi
  " || exit 1

  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null; rm -f "$GLPID"; }
  GT_LOCAL_PORT=$LOCAL_PORT GT_REMOTE_PORT=$LPORT \
    setsid python3 -u "$GT_GTLOCAL" >"$GLLOG" 2>&1 </dev/null &
  echo $! > "$GLPID"
  sleep 1
  ss -ltn 2>/dev/null | grep -q ":$LOCAL_PORT " \
    && echo "gtlocal up: $(head -1 "$GLLOG")" \
    || { echo "gtlocal FAILED:"; cat "$GLLOG"; exit 1; }

  cat <<EOT

Now start the sing-box app with sing-box-android.json. Its socks outbound must
point at 127.0.0.1:$LOCAL_PORT, and the tun inbound must carry
  "exclude_package": ["com.termux"]
or ssh's carrier is captured by the tunnel it carries.
EOT
}

down(){
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null
  have_ctl && ssh -S "$CTL" "$RHOST" \
    "P=/tmp/globaltun-server-$RPORT_SS.pid; [ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P; true"
  [ -S "$CTL" ] && ssh -S "$CTL" -O exit "$RHOST" 2>/dev/null
  rm -f "$CTL"
  echo "down (stop the VPN in the sing-box app too)"
}

status(){
  echo "--- carrier";  have_ctl && echo "  connected" || echo "  no control socket"
  echo "--- forward";  ss -ltn 2>/dev/null | grep ":$LPORT " || echo "  no :$LPORT listener"
  echo "--- gtlocal";  ss -ltn 2>/dev/null | grep ":$LOCAL_PORT " || echo "  not listening"
  echo "--- egress";   curl -s --max-time 20 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc)=' || echo "  unreachable"
  echo "--- gtlocal log"; tail -3 "$GLLOG" 2>/dev/null
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 2 ;;
esac
