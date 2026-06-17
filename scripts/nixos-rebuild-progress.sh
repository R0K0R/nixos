#!/usr/bin/env bash
# Watch nixos-rebuild-switch progress in another terminal (does not touch the build).
set -euo pipefail

HOST="${1:-galaxybook4-pro360}"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nixos-rebuild-switch/${HOST}"
PATHS="${STATE_DIR}/paths.txt"
LOG="${STATE_DIR}/rebuild.log"
META="${STATE_DIR}/meta.env"

if [[ ! -f "${PATHS}" ]]; then
  echo "No progress data yet. Is nixos-rebuild-switch.sh running for ${HOST}?" >&2
  echo "Expected: ${STATE_DIR}/" >&2
  exit 1
fi

total="$(wc -l < "${PATHS}")"

count_ready() {
  local ready=0 p
  while IFS= read -r p; do
    [[ -e "${p}" ]] && ready=$((ready + 1))
  done < "${PATHS}"
  echo "${ready}"
}

print_once() {
  local ready pct phase
  ready="$(count_ready)"
  pct=$((ready * 100 / total))
  phase="building system"
  if [[ -f "${META}" ]]; then
    # shellcheck disable=SC1090
    source "${META}"
  fi
  if [[ -f "${LOG}" ]] && grep -q 'activating the configuration' "${LOG}" 2>/dev/null; then
    phase="activating (almost done)"
  elif [[ -f "${LOG}" ]] && grep -q 'building the system configuration' "${LOG}" 2>/dev/null; then
    phase="building system closure"
  elif [[ -f "${LOG}" ]] && grep -q "building '/nix/store/.*nixos-rebuild" "${LOG}" 2>/dev/null; then
    phase="building nixos-rebuild"
  fi

  printf '%s/%s store paths ready (%s%%) — %s\n' "${ready}" "${total}" "${pct}" "${phase}"

  if [[ -f "${LOG}" ]]; then
    tail -n 1 "${LOG}" | sed 's/^/  → /'
  fi
}

if [[ "${2:-}" == "--once" ]]; then
  print_once
  exit 0
fi

while true; do
  clear
  echo "nixos-rebuild ${HOST} (Ctrl-C to stop watching; build keeps running)"
  echo
  print_once
  echo
  echo "Log: ${LOG}"
  sleep 5
done
