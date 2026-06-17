#!/usr/bin/env bash
# Run nixos-rebuild switch and print one readable root error instead of 200-line cascades.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run with bash, not sh: bash $0 $*" >&2
  exit 2
fi
set -euo pipefail

HOST="${1:-galaxybook4-pro360}"
FLAKE_DIR="${HOME}/flakes/nixos"
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/nixos-rebuild-switch/${HOST}"
LOG="${STATE_DIR}/rebuild.log"
PATHS="${STATE_DIR}/paths.txt"
META="${STATE_DIR}/meta.env"
FLAKE=".#nixosConfigurations.${HOST}"
TOPLEVEL="${FLAKE}.config.system.build.toplevel"

mkdir -p "${STATE_DIR}"
: > "${LOG}"

cd "${FLAKE_DIR}"

extra=()
if ! nix show-config 2>/dev/null | grep -q '^builders = @/etc/nix/machines'; then
  extra=(
    --builders '@/etc/nix/machines'
    --option builders-use-substitutes true
  )
fi
echo "Counting store paths in system closure (for progress)…"
if ! nix path-info -r "${TOPLEVEL}" ${extra+"${extra[@]}"} > "${PATHS}" 2>"${STATE_DIR}/path-info.err"; then
  echo "Warning: could not pre-count paths; progress watcher will be unavailable." >&2
  cat "${STATE_DIR}/path-info.err" >&2 || true
  rm -f "${PATHS}"
fi

{
  echo "host=${HOST}"
  echo "started=$(date -Iseconds)"
  echo "total_paths=$(wc -l < "${PATHS}" 2>/dev/null || echo 0)"
} > "${META}"

echo "→ sudo nixos-rebuild switch --flake ${FLAKE} ${extra[*]:-}"
if [[ -f "${PATHS}" ]]; then
  echo "→ progress (other terminal): bash ~/flakes/nixos/scripts/nixos-rebuild-progress.sh ${HOST}"
fi

set +e
sudo nixos-rebuild switch --flake "${FLAKE}" ${extra+"${extra[@]}"} --print-build-logs 2>&1 | tee -a "${LOG}"
status="${PIPESTATUS[0]}"
set -e

(( status == 0 )) && exit 0

echo >&2
echo "═══════════════════════════════════════════════════════════════" >&2
echo "  REBUILD FAILED — root cause (cascade noise stripped)" >&2
echo "═══════════════════════════════════════════════════════════════" >&2

if grep -q "on 'ssh://" "${LOG}"; then
  grep -E "error: build of '/nix/store/[^']+' on 'ssh://" "${LOG}" | head -3 >&2 || true
  grep -E "builder for '/nix/store/[^']+' failed|Reason: builder failed" "${LOG}" | head -3 >&2 || true
fi

grep -E "^error: The option|^error: |Reason: missing system features|Reason: local builds are disabled" "${LOG}" \
  | grep -v '1 dependency failed' \
  | grep -v 'Build failed due to failed dependency' \
  | head -15 >&2 || true

drv="$(
  awk '
    /Reason: builder failed|Reason: missing system features|Reason: local builds are disabled/ { print; exit }
  ' "${LOG}" \
  | grep -oE "/nix/store/[a-z0-9]{32}-[^.]+\.drv" \
  | head -1
)"
if [[ -z "${drv}" ]]; then
  drv="$(grep -oE "/nix/store/[a-z0-9]{32}-[^.]+\.drv" "${LOG}" | head -1)"
fi

if [[ -n "${drv}" ]]; then
  echo >&2
  echo "  Full build log:  nix log ${drv}" >&2
  echo "  Last 30 lines:" >&2
  echo "───────────────────────────────────────────────────────────────" >&2
  nix log "${drv}" 2>/dev/null | tail -30 >&2 || true
fi

if grep -q 'Reason: missing system features\|Reason: local builds are disabled' "${LOG}"; then
  echo >&2
  echo "  Hint: remote builders may not be active. Run:" >&2
  echo "    bash ~/flakes/nixos/scripts/bootstrap-yulee-builder-on-laptop.sh" >&2
fi

exit "${status}"
