#!/usr/bin/env bash
# eval-matrix.sh [--with-emacs] [-j N] [flake-dir] [host/variant ...]
#
# Evaluates every lib.matrix.<host>.<variant> toplevel drvPath (lib/matrix.nix)
# and reports pass/fail against the variant's expectation. NEVER BUILDS:
# builders '' and max-jobs 0, so an import-from-derivation whose output is not
# already in the store (or substitutable from cache.nixos.org) makes the eval
# FAIL instead of building it. Instantiating writes .drv files to the store;
# that is all.
#
# --with-emacs uses lib.matrixWithEmacs. A variant can then fail on the
# doom-emacs IFD when its inputs are not already in the store (expectation
# shown as "pass?"). Its <host>/all toplevel must equal the real host's.
#
# Selection: pass host/variant pairs (e.g. victus-15/ccache) to run only those.
# Logs: $LOGDIR (default: a mktemp dir), one file per variant.
set -uo pipefail

attr=matrix
jobs=2
while [ $# -gt 0 ]; do
  case $1 in
    --with-emacs) attr=matrixWithEmacs; shift ;;
    -j) jobs=$2; shift 2 ;;
    *) break ;;
  esac
done
dir=${1:-$(cd "$(dirname "$0")/.." && pwd)}
[ $# -gt 0 ] && shift
dir=$(realpath "$dir")

nixopts=(--option builders '' --option max-jobs 0 --option substituters 'https://cache.nixos.org')
LOGDIR=${LOGDIR:-$(mktemp -d -t eval-matrix.XXXXXX)}
mkdir -p "$LOGDIR"

info=$(nix eval --json "${nixopts[@]}" "$dir#lib.matrixInfo" 2>/dev/null) || {
  echo "cannot evaluate $dir#lib.matrixInfo" >&2; exit 2; }

if [ $# -gt 0 ]; then
  pairs=("$@")
else
  mapfile -t pairs < <(jq -r '.hosts[] as $h | .variants | keys[] | "\($h)/\(.)"' <<<"$info")
fi

run_one() {
  local pair=$1 h=${1%%/*} v=${1#*/} log
  log="$LOGDIR/${h}__${v}.log"
  local t0=$SECONDS
  # Re-declared here: arrays do not survive export into xargs' bash -c.
  local nixopts=(--option builders '' --option max-jobs 0 --option substituters 'https://cache.nixos.org')
  if nix eval --raw "${nixopts[@]}" \
       "$dir#lib.$attr.\"$h\".\"$v\".config.system.build.toplevel.drvPath" >"$log.out" 2>"$log"; then
    echo "$pair pass $((SECONDS - t0))s $(cat "$log.out")"
  else
    # The most useful line of a nix error is usually the last "error:" one.
    echo "$pair fail $((SECONDS - t0))s $(grep -E '^(error|       error):|^ *- ' "$log" | tail -2 | tr '\n' ' ' | cut -c1-240)"
  fi
}
export -f run_one
export dir attr LOGDIR

results=$(printf '%s\n' "${pairs[@]}" | xargs -P "$jobs" -I{} bash -c 'run_one "$1"' _ {})

echo
printf '%-34s %-6s %-6s %s\n' VARIANT RESULT EXPECT DETAIL
bad=0
while read -r pair res secs rest; do
  [ -n "$pair" ] || continue
  v=${pair#*/}
  exp=$(jq -r --arg v "$v" '.variants[$v].expect // "?"' <<<"$info")
  why=$(jq -r --arg v "$v" '.variants[$v].why // ""' <<<"$info")
  if [ "$attr" = matrixWithEmacs ] && [ "$exp" = pass ]; then exp="pass?"; fi
  mark=""
  case "$exp" in
    pass) [ "$res" = pass ] || { mark=" <-- UNEXPECTED"; bad=1; } ;;
    fail) [ "$res" = fail ] || { mark=" <-- UNEXPECTED"; bad=1; } ;;
  esac
  printf '%-34s %-6s %-6s %s%s\n' "$pair" "$res" "$exp" "$secs ${why:+($why) }$rest" "$mark"
done < <(sort <<<"$results")
echo
echo "logs: $LOGDIR"
exit $bad
