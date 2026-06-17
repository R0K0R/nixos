#!/usr/bin/env bash
# Join laptop (+ optionally Yulee) to Headscale and test p2p.
#
# Prereqs:
#   - Headscale serve running on Termux with server_url: http://airbow.kro.kr:8080
#   - Preauth key:
#       headscale users list
#       headscale preauthkeys create --user 1 --reusable --expiration 24h
#
# Tailscale 1.80+ breaks plain-HTTP Headscale (tries https://host:8080 then :443).
# This script pins tailscale 1.76.x unless TAILSCALE_LEGACY=0.
# Long-term fix: enable TLS on Headscale (https on :8080) or open :443.
#
# Usage:
#   export TS_AUTHKEY='hskey-auth-...'   # or tskey-auth-...
#   bash ~/flakes/nixos/scripts/headscale-p2p-test.sh
#
#   Laptop only:
#   SKIP_YULEE=1 bash ~/flakes/nixos/scripts/headscale-p2p-test.sh
#
#   Force fresh login (clears local tailscale state):
#   REFRESH=1 bash ~/flakes/nixos/scripts/headscale-p2p-test.sh
set -euo pipefail

LOGIN_SERVER="${LOGIN_SERVER:-http://airbow.kro.kr:8080}"
YULEE_HOST="${YULEE_HOST:-yulee}"
LAPTOP_NAME="${LAPTOP_NAME:-galaxybook4-pro360}"
YULEE_NAME="${YULEE_NAME:-yulee}"
SKIP_YULEE="${SKIP_YULEE:-0}"
TAILSCALE_LEGACY="${TAILSCALE_LEGACY:-1}"
# nixpkgs pin with tailscale 1.76.x (before HTTP Headscale regression)
TAILSCALE_NIXPKGS="${TAILSCALE_NIXPKGS:-https://github.com/NixOS/nixpkgs/archive/nixos-24.05.tar.gz}"
REFRESH="${REFRESH:-0}"

tailscale_nix_shell() {
  if [[ "${TAILSCALE_LEGACY}" == "1" ]]; then
    sudo nix-shell -p "(with import (fetchTarball \"${TAILSCALE_NIXPKGS}\") {}; tailscale)" jq "$@"
  else
    sudo nix-shell -p tailscale jq "$@"
  fi
}

refresh_args=""
if [[ "${REFRESH}" == "1" ]]; then
  refresh_args="--reset --force-reauth"
fi

if [[ -z "${TS_AUTHKEY:-}" ]]; then
  echo "Set TS_AUTHKEY first, e.g.:" >&2
  echo "  export TS_AUTHKEY='hskey-auth-...'" >&2
  echo "  headscale preauthkeys create --user 1 --reusable --expiration 24h" >&2
  exit 1
fi

if ! curl -sf --max-time 5 "${LOGIN_SERVER}/" >/dev/null; then
  echo "Cannot reach Headscale at ${LOGIN_SERVER}" >&2
  exit 1
fi

if [[ "${LOGIN_SERVER}" == http://* ]] && [[ "${TAILSCALE_LEGACY}" != "1" ]]; then
  echo "WARNING: HTTP Headscale needs tailscale <1.80. Set TAILSCALE_LEGACY=1 (default)." >&2
fi

echo "=== Laptop (${LAPTOP_NAME}) ==="
if [[ "${TAILSCALE_LEGACY}" == "1" ]]; then
  echo "Using pinned tailscale 1.76.x (TAILSCALE_LEGACY=1)"
fi
tailscale_nix_shell --run bash <<EOF
set -euo pipefail
LOGIN_SERVER='${LOGIN_SERVER}'
TS_AUTHKEY='${TS_AUTHKEY}'
NAME='${LAPTOP_NAME}'
REFRESH_ARGS='${refresh_args}'
USE_LEGACY='${TAILSCALE_LEGACY}'

ensure_tailscaled() {
  local tailscaled_bin
  tailscaled_bin="\$(command -v tailscaled)"

  if [[ "\${USE_LEGACY}" == "1" ]]; then
    systemctl stop tailscaled 2>/dev/null || true
    pkill -x tailscaled 2>/dev/null || true
    rm -f /run/tailscale/tailscaled.sock
  elif tailscale status --peers=false &>/dev/null; then
    return 0
  elif systemctl list-unit-files tailscaled.service &>/dev/null; then
    systemctl start tailscaled 2>/dev/null || true
    sleep 2
    tailscale status --peers=false &>/dev/null && return 0
  elif pgrep -x tailscaled >/dev/null || [[ -S /run/tailscale/tailscaled.sock ]]; then
    echo "tailscaled already running (or socket busy); not starting another." >&2
    tailscale status --peers=false &>/dev/null && return 0
    echo "Daemon not responding. Try: sudo systemctl restart tailscaled" >&2
    exit 1
  fi

  mkdir -p /var/lib/tailscale /run/tailscale
  "\${tailscaled_bin}" \\
    --state=/var/lib/tailscale/tailscaled.state \\
    --socket=/run/tailscale/tailscaled.sock &
  sleep 2
  tailscale status --peers=false &>/dev/null || {
    echo "tailscaled failed to start." >&2
    exit 1
  }
}

ensure_tailscaled
# shellcheck disable=SC2086
tailscale up \\
  --login-server="\${LOGIN_SERVER}" \\
  --auth-key="\${TS_AUTHKEY}" \\
  --hostname="\${NAME}" \\
  --accept-routes \\
  --accept-dns=false \${REFRESH_ARGS}
tailscale status
EOF

if [[ "${SKIP_YULEE}" == "1" ]]; then
  echo "SKIP_YULEE=1 — done after laptop."
  exit 0
fi

echo
echo "=== Yulee (${YULEE_NAME}) — ssh -t for sudo password ==="
ssh -t "${YULEE_HOST}" env \
  TS_AUTHKEY="${TS_AUTHKEY}" \
  LOGIN_SERVER="${LOGIN_SERVER}" \
  YULEE_NAME="${YULEE_NAME}" \
  REFRESH_ARGS="${refresh_args}" \
  bash -s <<'REMOTE'
set -euo pipefail
if ! command -v tailscale >/dev/null; then
  echo "Install tailscale on Yulee first." >&2
  exit 1
fi
ensure_tailscaled() {
  if tailscale status --peers=false &>/dev/null; then
    return 0
  fi
  if systemctl list-unit-files tailscaled.service &>/dev/null; then
    sudo systemctl start tailscaled 2>/dev/null || true
    sleep 2
    tailscale status --peers=false &>/dev/null && return 0
  fi
  if pgrep -x tailscaled >/dev/null || [[ -S /run/tailscale/tailscaled.sock ]]; then
    echo "tailscaled already running (or socket busy); not starting another." >&2
    tailscale status --peers=false &>/dev/null && return 0
    echo "Daemon not responding. Try: sudo systemctl restart tailscaled" >&2
    exit 1
  fi
  sudo mkdir -p /var/lib/tailscale /run/tailscale
  sudo tailscaled \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/run/tailscale/tailscaled.sock &
  sleep 2
}
ensure_tailscaled
# shellcheck disable=SC2086
sudo tailscale up \
  --login-server="${LOGIN_SERVER}" \
  --auth-key="${TS_AUTHKEY}" \
  --hostname="${YULEE_NAME}" \
  --accept-routes \
  --accept-dns=false \
  ${REFRESH_ARGS}
sudo tailscale status
REMOTE

echo
echo "=== P2P check: laptop → ${YULEE_NAME} ==="
tailscale_nix_shell --run "tailscale ping --c 5 --verbose ${YULEE_NAME}" || true

echo
echo "=== Direct vs relay ==="
tailscale_nix_shell --run "
  tailscale status --json \
    | jq -r '.Peer[]? | select(.HostName==\"${YULEE_NAME}\") | \"Host: \\(.HostName)\\nTailscaleIPs: \\(.TailscaleIPs)\\nCurAddr: \\(.CurAddr // \"none\")\\nRelay: \\(.Relay // \"none\")\\nOnline: \\(.Online)\"'
" || tailscale status

echo
echo "CurAddr set  ⇒  likely p2p.  Relay only  ⇒  via DERP (still works)."
