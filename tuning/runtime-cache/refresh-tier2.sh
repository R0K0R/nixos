#!/usr/bin/env bash
# Tier 2 of the host-runtime classifier: the cached eval-time heuristic
# (runtime-cache/tier2-eval.nix), refreshed manually and written to a
# git-tracked cache file. Run from any machine (this does its own standalone
# NixOS eval per host, it does not need to run ON that host):
#   ./refresh-tier2.sh <hostname>|all
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
. ./cache-dir.sh

refresh_one() {
  local HOST="$1"
  if [ ! -d "$FLAKE_ROOT/hosts/$HOST" ]; then
    echo "no hosts/$HOST -- pass an explicit hostname matching a hosts/ directory" >&2
    exit 1
  fi

  local OUT TMP_OUT DIR rc=0
  DIR=$(cache_dir "$HOST") || rc=$?
  case $rc in
    0) ;;
    3) echo "tier2 for $HOST SKIPPED here" >&2; return 0 ;;
    *) exit 1 ;;
  esac
  OUT="$DIR/system-tier2.nix"
  TMP_OUT="$(mktemp)"
  local CAPTURED_AT
  CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  echo "evaluating tier2 for $HOST (constructs a throwaway NixOS+home-manager config, ~15-20s)..."
  nix eval --impure --expr "
    let
      r = import $FLAKE_ROOT/tuning/runtime-cache/tier2-eval.nix { host = \"$HOST\"; };
    in
    r // { capturedAt = \"$CAPTURED_AT\"; }
  " > "$TMP_OUT"
  if command -v nixfmt >/dev/null 2>&1; then
    nixfmt "$TMP_OUT"
  fi
  put_cache "$TMP_OUT" "$OUT"
  echo "wrote $OUT"
}

if [ "${1:-}" = "all" ]; then
  for d in "$FLAKE_ROOT"/hosts/*/; do
    refresh_one "$(basename "$d")"
  done
elif [ -n "${1:-}" ]; then
  refresh_one "$1"
else
  echo "usage: ./refresh-tier2.sh <hostname>|all" >&2
  exit 1
fi
