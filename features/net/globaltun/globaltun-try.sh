#!/usr/bin/env bash
# globaltun-try -- gated, self-reverting bring-up. For headless hosts, where a
# failed `up` can cut the only way back in.
#
# Three properties matter, in this order:
#   1. It refuses to touch routing unless the carrier is reachable RIGHT NOW.
#      That hop alternates between ~20ms and unreachable, and spending a
#      bring-up during a bad phase just leaves a half-configured box.
#   2. It arms the dead-man switch BEFORE `up`, and aborts if arming fails.
#      A switch armed afterwards is useless: `up` is when you lose the session.
#   3. It reverts and disarms by itself if `up` fails, so a failed attempt
#      leaves nothing behind.
#
# Usage: sudo ./globaltun-try.sh [minutes]      (default 10)
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$HERE/globaltun.env" ] && . "$HERE/globaltun.env"

[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
GT="$HERE/globaltun.sh"
[ -x "$GT" ] || { echo "no globaltun script beside $0" >&2; exit 1; }

MINUTES=${1:-10}
UNIT=globaltun-deadman
PROBES=${GT_PREFLIGHT_PROBES:-3}
GW_HOST=${GT_RHOST##*@}
GW_PORT=${GT_RPORT:-8022}
JUMPS=${GT_JUMPS:-${GT_JUMP:-}}

disarm(){ systemctl stop "$UNIT.timer" 2>/dev/null
          systemctl reset-failed "$UNIT.timer" "$UNIT.service" 2>/dev/null; }

JUMP_LIST=()
for _j in ${JUMPS//,/ }; do JUMP_LIST+=("$_j"); done
NJUMPS=${#JUMP_LIST[@]}
# The hop that must reach the gateway is the LAST one, and it is reached
# through the ones before it. Rather than rebuild that chain here, borrow the
# one globaltun.sh generates -- its Host blocks already carry the key and the
# ProxyJump links, so a bare `-F cfg gt-hop-N` walks the whole path.
SSHCFG=$("$GT" ssh-config 2>/dev/null || true)

# Probe the gateway from wherever the carrier actually originates: locally when
# dialling direct, otherwise from the last jump, which is what has to reach it.
probe_once(){
  if [ "$NJUMPS" -gt 0 ] && [ -n "$SSHCFG" ]; then
    timeout 40 ssh -F "$SSHCFG" -o BatchMode=yes "gt-hop-$NJUMPS" \
      "timeout 20 bash -c 'exec 3<>/dev/tcp/$GW_HOST/$GW_PORT'" >/dev/null 2>&1
  else
    timeout 20 bash -c "exec 3<>/dev/tcp/$GW_HOST/$GW_PORT" >/dev/null 2>&1
  fi
}

echo "== preflight: $PROBES probes to $GW_HOST:$GW_PORT${JUMPS:+ (via $JUMPS)}"
ok=0
for i in $(seq 1 "$PROBES"); do
  if probe_once; then ok=$((ok+1)); echo "   probe $i OK"; else echo "   probe $i FAIL"; fi
  [ "$i" -lt "$PROBES" ] && sleep 3
done
if [ "$ok" -lt "$PROBES" ]; then
  echo "== ABORT: only $ok/$PROBES reachable -- bad phase. Nothing was changed." >&2
  exit 1
fi

echo "== arming dead-man switch ('down' in ${MINUTES}m)"
disarm
if ! systemd-run --on-active="${MINUTES}min" --unit="$UNIT" "$GT" down >/dev/null 2>&1; then
  echo "== ABORT: could not arm the switch; refusing to touch routing" >&2
  exit 1
fi
echo "   armed"

echo "== up"
if ! "$GT" up; then
  echo "== up FAILED -- reverting and disarming"
  "$GT" down >/dev/null 2>&1
  disarm
  exit 1
fi

echo "== verify"
"$GT" verify
rc=$?

cat <<EOT

== switch still armed: it runs 'down' in ${MINUTES}m unless you stop it
   keep it up  : systemctl stop $UNIT.timer && systemctl reset-failed $UNIT.timer $UNIT.service
   drop it now : $GT down && systemctl stop $UNIT.timer && systemctl reset-failed $UNIT.timer $UNIT.service
   watch       : journalctl -fu $UNIT.service
EOT
exit $rc
