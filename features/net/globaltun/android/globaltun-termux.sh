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
# QUIC (optional, alongside ssh -- set GT_QUIC_PORT): the sing-box APP speaks
# Hysteria2 itself, so with QUIC the phone's traffic goes straight from the app
# to the gateway over UDP, and Termux is not in the data path at all. Termux
# then only starts the server over ssh, keeps the ssh path as the fallback, and
# writes the app profile that holds both:
#
#   sing-box app --+-- quic: Hysteria2/UDP -> gateway            (preferred)
#                  +-- ssh:  socks 127.0.0.1:$LOCAL_PORT -> above (fallback)
#
# Unlike the Linux client, the credentials are KEPT (in ~/.globaltun-quic):
# the app reads its profile only when you import it, so per-run credentials
# would mean re-importing on every `up`. `quic-reset` makes new ones.
#
# With QUIC, `up` also starts a watcher (`watch`, in the background): the app's
# "proxy" switch defaults to QUIC, and the watcher moves it to the ssh path
# while QUIC is down and back once QUIC has held -- through the app's API on
# the phone's loopback (127.0.0.1:11090, with a secret kept in ~/.globaltun-quic).
#
# Usage: ./globaltun-termux.sh {up|down|status|quic-reset}
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/globaltun.env" ]; then
  . "$HERE/globaltun.env"
else
  echo "no globaltun.env beside $0 -- copy android/globaltun.env from the repo with it" >&2
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
# Proxy hops and per-hop credentials exist in globaltun.sh only. Refuse them
# here by name: this client's chain writer would otherwise turn
# `socks5://host:port` into `HostName socks5` and fail two hops later as an
# ssh error that points nowhere near the cause.
for _j in "${JUMP_LIST[@]}"; do
  case $_j in *://*|*=*)
    echo "hop '$_j': proxy hops and per-hop credentials are not supported by the" >&2
    echo "Termux client yet -- only [user@]host[:port], authenticated with GT_KEY." >&2
    exit 1 ;;
  esac
done
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
  # Same for the QUIC server (only needed with GT_QUIC_PORT).
  [ -z "${GT_QUIC_BIN_DIR:-}" ] && { [ -f "$d/gtquic-linux-amd64" ] || [ -f "$d/gtquic-linux-arm64" ]; } && GT_QUIC_BIN_DIR=$d
  [ -z "${GT_APP_TEMPLATE:-}" ] && [ -f "$d/sing-box-android.json" ] && GT_APP_TEMPLATE=$d/sing-box-android.json
done
GT_RELAY_DIR=${GT_RELAY_DIR:-}
GT_QUIC_BIN_DIR=${GT_QUIC_BIN_DIR:-}
GT_APP_TEMPLATE=${GT_APP_TEMPLATE:-}
[ -n "${GT_RSOCKS:-}" ]  || { echo "rsocks.py not found beside or above $HERE" >&2; exit 1; }
[ -n "${GT_GTLOCAL:-}" ] || { echo "gtlocal.py not found beside or above $HERE" >&2; exit 1; }

# Termux has no /run; keep runtime state where the app can actually write.
RT=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
CTL=$RT/globaltun.ctl
GLPID=$RT/globaltun-gtlocal.pid
GLLOG=$RT/globaltun-gtlocal.log

QUIC_PORT=${GT_QUIC_PORT:-}
# An IP literal: the phone's own DNS is on the network with no way out, and the
# app would resolve a name through the very tunnel it is trying to reach.
QUIC_HOST=${GT_QUIC_HOST:-${RHOST##*@}}
QUIC_HOST=${QUIC_HOST%%:*}
QUIC_DIR=${GT_QUIC_DIR:-$HOME/.globaltun-quic}
QUIC_RDIR=/tmp/globaltun-quic-$QUIC_PORT
# Where the rendered app profile goes. Termux's private files are invisible to
# the app, so it is copied to shared storage when `termux-setup-storage` has
# been run (~/storage/downloads), and also written beside this script.
QUIC_PROFILE_NAME=globaltun-quic.json
QUIC_API=127.0.0.1:11090
WATCH_PID=$RT/globaltun-watch.pid
WATCH_LOG=$RT/globaltun-watch.log
# ssh-only, but with vpns.d/ snippets merged in
SSH_PROFILE_NAME=globaltun-ssh.json
PROFILE=

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

# --- QUIC ---------------------------------------------------------------------

# Kept across runs on purpose (see the header). openssl-tool provides openssl:
#   pkg install openssl-tool
quic_creds(){
  # The API secret came later than the rest: add it alone, so credentials
  # (and the gateway password in an imported profile) stay as they are.
  if [ -s "$QUIC_DIR/password" ] && [ ! -s "$QUIC_DIR/api_secret" ] && command -v openssl >/dev/null; then
    ( umask 077; openssl rand -hex 16 > "$QUIC_DIR/api_secret" )
  fi
  [ -s "$QUIC_DIR/cert.pem" ] && [ -s "$QUIC_DIR/key.pem" ] && [ -s "$QUIC_DIR/password" ] \
    && [ -s "$QUIC_DIR/api_secret" ] && return 0
  command -v openssl >/dev/null || { echo "  quic: needs openssl -- pkg install openssl-tool" >&2; return 1; }
  ( umask 077; mkdir -p "$QUIC_DIR"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -keyout "$QUIC_DIR/key.pem" -out "$QUIC_DIR/cert.pem" -days 3650 \
      -subj /CN=globaltun -addext subjectAltName=DNS:globaltun 2>/dev/null
    openssl rand -hex 16 > "$QUIC_DIR/password"
    openssl rand -hex 16 > "$QUIC_DIR/api_secret" )
  [ -s "$QUIC_DIR/cert.pem" ] && [ -s "$QUIC_DIR/password" ] \
    || { echo "  quic: could not generate credentials" >&2; rm -rf "$QUIC_DIR"; return 1; }
  echo "  quic: new credentials in $QUIC_DIR -- import the profile below into the app"
}

# Push (content-addressed, like the relay: 40MB, once per gateway) and start the
# Hysteria2 server with the kept credentials. Stopped by its pidfile, never
# `pkill -f`, whose pattern would also match the shell running it.
start_remote_quic(){
  local arch bin sum rp pw
  arch=$(rsh1 'uname -m' 2>/dev/null | tr -d '\r')
  case $arch in
    x86_64|amd64)                bin=$GT_QUIC_BIN_DIR/gtquic-linux-amd64 ;;
    aarch64|arm64|armv8*|armv9*) bin=$GT_QUIC_BIN_DIR/gtquic-linux-arm64 ;;
    *)                           bin= ;;
  esac
  [ -n "$GT_QUIC_BIN_DIR" ] && [ -n "$bin" ] && [ -f "$bin" ] || {
    echo "  quic: no gtquic-linux-* for gateway arch '${arch:-unknown}' in this bundle" >&2; return 1; }
  sum=$(sha256sum "$bin" | cut -c1-16); rp=/tmp/gtquic-$sum
  if ! rsh1 "test -x $rp" 2>/dev/null; then
    echo "  quic: pushing $(du -h "$bin" | cut -f1) server binary (once per gateway)..."
    ssh -S "$CTL" "$RHOST" "/bin/sh -c 'cat > $rp.part && chmod +x $rp.part && mv $rp.part $rp'" < "$bin" \
      || { echo "  quic: push failed" >&2; return 1; }
  fi
  pw=$(cat "$QUIC_DIR/password")
  # Leave a running server alone when it is this exact binary, port and
  # credentials: restarting it cuts the app's live QUIC connection for nothing
  # (that is how the app got parked on ssh on 2026-11-17). The marker is a hash
  # of what this function would write; anything different restarts it.
  local mark
  # Includes this function's own text, which holds the server config template:
  # a changed config (e.g. logging turned off) restarts the server once.
  mark=$( { echo "$rp $QUIC_PORT"; declare -f start_remote_quic; cat "$QUIC_DIR/cert.pem" "$QUIC_DIR/key.pem" "$QUIC_DIR/password"; } | sha256sum | cut -c1-32)
  if rsh1 "test -f $QUIC_RDIR/pid && kill -0 \$(cat $QUIC_RDIR/pid) && test \"\$(cat $QUIC_RDIR/mark 2>/dev/null)\" = $mark" >/dev/null 2>&1; then
    echo "remote quic server already running with these credentials -- left as is"
    return 0
  fi
  # The server dials destinations itself, preferring IPv6: sing-box's default
  # took IPv4 first, which on yulee cost ~190 ms per new connection (measured
  # 2026-11-17: HTTPS to gstatic 343 ms over v4, 156 over v6; QUIC probes
  # 308-365 -> 134-170 ms) and made QUIC probe slower than the ssh path, whose
  # Go relay already prefers v6. A gateway with broken v6 loses at most
  # sing-box's 300 ms fallback to v4, as the relay does.
  rsh <<EOF
D=$QUIC_RDIR
[ -f \$D/pid ] && kill \$(cat \$D/pid) 2>/dev/null
rm -rf \$D; umask 077; mkdir -p \$D
cat > \$D/cert.pem <<'GTEOF'
$(cat "$QUIC_DIR/cert.pem")
GTEOF
cat > \$D/key.pem <<'GTEOF'
$(cat "$QUIC_DIR/key.pem")
GTEOF
cat > \$D/server.json <<'GTEOF'
{"log":{"disabled":true},
 "inbounds":[{"type":"hysteria2","tag":"quic-in","listen":"0.0.0.0","listen_port":$QUIC_PORT,
   "users":[{"password":"$pw"}],
   "tls":{"enabled":true,"alpn":["h3"],"certificate_path":"$QUIC_RDIR/cert.pem","key_path":"$QUIC_RDIR/key.pem"}}],
 "outbounds":[{"type":"direct","tag":"direct"}],
 "dns":{"servers":[{"type":"local","tag":"local"}]},
 "route":{"default_domain_resolver":{"server":"local","strategy":"prefer_ipv6"}}}
GTEOF
# NOTHING is written on the gateway: logging is disabled in the config and the
# process's own output goes to /dev/null. Even at warn level sing-box logs a
# failed connection WITH its destination, and the gateway is somebody else's
# box. Startup is proven without a log instead: the config checks out, and the
# process is still alive two seconds later.
$rp check -c \$D/server.json || { echo 'remote quic server: config rejected (above)'; exit 1; }
S=\$(command -v setsid || command -v nohup || true)
\$S $rp run -c \$D/server.json >/dev/null 2>&1 </dev/null &
echo \$! > \$D/pid
echo $mark > \$D/mark
sleep 2
if kill -0 \$(cat \$D/pid) 2>/dev/null; then
  echo "remote quic server up: udp/$QUIC_PORT pid \$(cat \$D/pid) (logs nothing)"
else
  # Show why on THIS terminal only -- a few seconds in the foreground, output
  # straight back over ssh, never into a file.
  echo 'remote quic server FAILED to stay up; its startup output:'
  timeout 3 $rp run -c \$D/server.json 2>&1 </dev/null | head -5
  exit 1
fi
EOF
}

# The app profile, rendered by render-profile.py from sing-box-android.json:
# QUIC beside the ssh socks when QUIC is up, plus every snippet in vpns.d/
# (other VPNs carried INSIDE the app -- Android gives the VPN slot to one app
# only). Written only when there is something to add; otherwise the plain
# sing-box-android.json is the profile, as before.
#   $1 = 1 when the QUIC server is up
render_app_profile(){
  local quic_ok=$1 out args
  [ -n "$GT_APP_TEMPLATE" ] || { echo "  profile: sing-box-android.json not found beside or above $HERE" >&2; return 1; }
  [ -f "$HERE/render-profile.py" ] || { echo "  profile: render-profile.py missing from the bundle" >&2; return 1; }
  args=(--template "$GT_APP_TEMPLATE" --local-port "$LOCAL_PORT")
  if [ "$quic_ok" = 1 ]; then
    out=$HERE/$QUIC_PROFILE_NAME
    args+=(--quic "$QUIC_HOST" "$QUIC_PORT" "$QUIC_DIR/password" "$QUIC_DIR/cert.pem"
           --api "$QUIC_API" "$QUIC_DIR/api_secret")
  else
    out=$HERE/$SSH_PROFILE_NAME
  fi
  [ -d "$HERE/vpns.d" ] && args+=(--extras "$HERE/vpns.d")
  python3 "$HERE/render-profile.py" "${args[@]}" --out "$out" || return 1
  PROFILE=$out
  echo "  profile: $out"
  if [ -d "$HOME/storage/downloads" ]; then
    cp "$out" "$HOME/storage/downloads/${out##*/}" \
      && echo "           copied to Download/${out##*/} for the app to import"
  else
    echo "           run termux-setup-storage once to get it copied to Download/ for import"
  fi
}

stop_remote_quic(){
  [ -n "$QUIC_PORT" ] && have_ctl || return 0
  rsh <<EOF
D=$QUIC_RDIR
[ -f \$D/pid ] && kill \$(cat \$D/pid) 2>/dev/null; rm -rf \$D; true
EOF
}

# --- the transport watcher ----------------------------------------------------
# The same policy as the Linux client's carrier-watch: QUIC by default; 2 failed
# probes in a row (and ssh answering) -> ssh; 3 good QUIC probes -> back.
# Probes are one small HTTPS request through each outbound, via the app's API.

wlog(){ echo "$(date '+%F %T') $*" >> "$WATCH_LOG"; }
api(){ curl -s --noproxy '*' -H "Authorization: Bearer $(cat "$QUIC_DIR/api_secret" 2>/dev/null)" "$@"; }
quic_delay(){
  api -m $(( ${2:-5000} / 1000 + 3 )) \
    "http://$QUIC_API/proxies/$1/delay?timeout=${2:-5000}&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" \
    | grep -oE '"delay": *[0-9]+' | grep -oE '[0-9]+$'
}
quic_now(){ api -m 3 "http://$QUIC_API/proxies/proxy" | grep -oE '"now": *"[^"]*"' | cut -d'"' -f4; }
quic_select(){
  api -m 3 -X PUT -H 'Content-Type: application/json' -d "{\"name\":\"$1\"}" \
    -o /dev/null -w '%{http_code}' "http://$QUIC_API/proxies/proxy" | grep -q '^204$'
}
TW_QFAIL=0 TW_QOK=0
transport_watch(){
  local now qd
  now=$(quic_now)
  [ -n "$now" ] || return 0            # app not running (or no QUIC profile): nothing to steer
  qd=$(quic_delay quic 3000)
  if [ "$now" = quic ]; then
    if [ -n "$qd" ]; then TW_QFAIL=0; return 0; fi
    TW_QFAIL=$((TW_QFAIL + 1))
    if [ "$TW_QFAIL" -ge 2 ] && [ -n "$(quic_delay ssh 3000)" ] && quic_select ssh; then
      wlog "quic stopped answering ($TW_QFAIL probes); switched to ssh"
      TW_QFAIL=0 TW_QOK=0
    fi
  else
    if [ -z "$qd" ]; then TW_QOK=0; return 0; fi
    TW_QOK=$((TW_QOK + 1))
    if [ "$TW_QOK" -ge 3 ] && quic_select quic; then
      wlog "quic healthy again (${qd} ms, $TW_QOK probes); switched back from $now"
      TW_QFAIL=0 TW_QOK=0
    fi
  fi
}
watch_loop(){
  wlog "watching the app's transport switch (every ${GT_WATCH_INTERVAL:-10}s)"
  while :; do
    transport_watch
    # keep the log from growing without bound on a phone
    [ "$(wc -c < "$WATCH_LOG" 2>/dev/null || echo 0)" -gt 262144 ] && tail -n 200 "$WATCH_LOG" > "$WATCH_LOG.new" && mv "$WATCH_LOG.new" "$WATCH_LOG"
    sleep "${GT_WATCH_INTERVAL:-10}"
  done
}
watch_start(){
  watch_stop
  local d; d=$(command -v setsid || command -v nohup)
  $d bash "$0" watch </dev/null >/dev/null 2>&1 &
  echo $! > "$WATCH_PID"
  echo "watcher up (pid $(cat "$WATCH_PID")): keeps the app on QUIC whenever QUIC works"
}
watch_stop(){
  [ -f "$WATCH_PID" ] && kill "$(cat "$WATCH_PID")" 2>/dev/null
  rm -f "$WATCH_PID"
}

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

  # QUIC never makes `up` fail: without it the ssh path above is the whole
  # tunnel, exactly as before.
  QUIC_OK=0
  if [ -n "$QUIC_PORT" ]; then
    echo "--- quic (alongside ssh)"
    if quic_creds && start_remote_quic; then QUIC_OK=1
    else echo "(quic unavailable -- ssh only)"; fi
  fi
  if [ "$QUIC_OK" = 1 ] || ls "$HERE"/vpns.d/*.json >/dev/null 2>&1; then
    echo "--- app profile"
    render_app_profile "$QUIC_OK" || echo "(profile not rendered -- use sing-box-android.json)"
  fi
  [ "$QUIC_OK" = 1 ] && watch_start

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
  [ -n "$PROFILE" ] && cat <<EOT

Use ${PROFILE##*/} in the app instead of sing-box-android.json. Import it
again only when it changes (quic-reset, or a change in vpns.d/). It holds
credentials -- delete the copy in Download/ after importing.$([ "$QUIC_OK" = 1 ] && printf '\nThe app talks Hysteria2 to %s:%s itself and falls back to the ssh path above.' "$QUIC_HOST" "$QUIC_PORT")
EOT
  return 0
}

down(){
  watch_stop
  [ -f "$GLPID" ] && { kill "$(cat "$GLPID")" 2>/dev/null; rm -f "$GLPID"; }
  pkill -f 'python3 -u .*gtlocal.py' 2>/dev/null
  have_ctl && rsh <<EOF
P=/tmp/globaltun-server-$RPORT_SS.pid
[ -f \$P ] && kill \$(cat \$P) 2>/dev/null; rm -f \$P; true
EOF
  stop_remote_quic
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
  if [ -n "$QUIC_PORT" ]; then
    echo "--- quic server on the gateway (udp/$QUIC_PORT)"
    if have_ctl && rsh1 "test -f $QUIC_RDIR/pid && kill -0 \$(cat $QUIC_RDIR/pid)" >/dev/null 2>&1; then
      echo "  running"
    else
      echo "  not running"
    fi
    [ -s "$QUIC_DIR/password" ] && echo "  credentials: $QUIC_DIR (profile: $HERE/$QUIC_PROFILE_NAME)"
    echo "--- app transport (via its API)"
    _now=$(quic_now)
    if [ -n "$_now" ]; then
      echo "  carrying traffic: $_now   (quic $(quic_delay quic 3000 || true) ms, ssh $(quic_delay ssh 3000 || true) ms)"
    else
      echo "  app not answering on $QUIC_API -- VPN off, or a profile from before the watcher"
    fi
    if [ -f "$WATCH_PID" ] && kill -0 "$(cat "$WATCH_PID")" 2>/dev/null; then
      echo "  watcher: running$( [ -s "$WATCH_LOG" ] && echo "; last: $(tail -1 "$WATCH_LOG" | cut -c1-90)")"
    else
      echo "  watcher: NOT running (run up)"
    fi
  fi
}

case "${1:-}" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  watch)  watch_loop ;;
  # New certificate and password; the next `up` starts the server with them and
  # writes a new profile, which must be imported into the app again.
  quic-reset) rm -rf "${QUIC_DIR:?}" "${HERE:?}/${QUIC_PROFILE_NAME:?}"
              echo "quic credentials removed -- run up, then re-import $QUIC_PROFILE_NAME" ;;
  *) echo "usage: $0 {up|down|status|quic-reset}" >&2; exit 2 ;;
esac
