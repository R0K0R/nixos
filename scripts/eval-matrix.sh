#!/usr/bin/env bash
# eval-matrix.sh [--with-emacs] [-j N] [--list] [flake-dir] [PATTERN ...]
#
# Evaluates lib.matrix.<host>.<variant> toplevel drvPaths (lib/matrix.nix)
# and reports each against the variant's expectation:
#   pass            must evaluate;
#   fail: <text>    invalid by design: must FAIL, and the error must contain
#                   <text> (the assertion that says why). Failing for any
#                   other reason is as unexpected as passing.
# NEVER BUILDS: builders '' and max-jobs 0, so an import-from-derivation whose
# output is not already in the store (or substitutable from cache.nixos.org)
# makes the eval FAIL instead of building it. Instantiating writes .drv files
# to the store; that is all.
#
# SUBSET: PATTERNs are host/variant globs, e.g.
#   dell-latitude/*      every variant of the untuned (fast) host
#   */off */all          two variants everywhere
#   victus-15/btrfs-*    one host's btrfs variants
# Default: everything (3 hosts x ~25 variants; an IntraISACross host's
# variants take about a minute each, the upstream-nixpkgs ones seconds).
# --list prints the selected pairs and exits.
#
# -j N: parallel evaluations, default 1. Each holds a full NixOS evaluation in
# memory (several GB for the tuned hosts); keep it at 1 on a shared machine.
#
# --with-emacs uses lib.matrixWithEmacs. A variant can then fail on the
# doom-emacs IFD when its inputs are not already in the store (a `pass`
# expectation is shown as "pass?"). Its <host>/host variant must equal the
# real nixosConfigurations.<host> drvPath, which is checked here.
#
# Logs: $LOGDIR (default: a mktemp dir), one file per variant.
set -uo pipefail

attr=matrix
jobs=1
list=0
while [ $# -gt 0 ]; do
  case $1 in
    --with-emacs) attr=matrixWithEmacs; shift ;;
    -j) jobs=$2; shift 2 ;;
    --list) list=1; shift ;;
    *) break ;;
  esac
done
dir=$(cd "$(dirname "$0")/.." && pwd)
if [ $# -gt 0 ] && [ -e "$1/flake.nix" ]; then dir=$(realpath "$1"); shift; fi

nixopts=(--option builders '' --option max-jobs 0 --option substituters 'https://cache.nixos.org')
LOGDIR=${LOGDIR:-$(mktemp -d -t eval-matrix.XXXXXX)}
mkdir -p "$LOGDIR"

info=$(nix eval --json "${nixopts[@]}" "$dir#lib.matrixInfo" 2>"$LOGDIR/info.log") || {
  echo "cannot evaluate $dir#lib.matrixInfo:" >&2; cat "$LOGDIR/info.log" >&2; exit 2; }

mapfile -t every < <(jq -r '.variantsOf | to_entries[] | .key as $h | .value[] | "\($h)/\(.)"' <<<"$info")
pairs=()
if [ $# -gt 0 ]; then
  for p in "${every[@]}"; do
    for pat in "$@"; do
      # shellcheck disable=SC2053 # glob match on purpose
      if [[ $p == $pat ]]; then pairs+=("$p"); break; fi
    done
  done
  [ ${#pairs[@]} -gt 0 ] || { echo "no host/variant matches: $*" >&2; exit 2; }
else
  pairs=("${every[@]}")
fi
if [ "$list" = 1 ]; then printf '%s\n' "${pairs[@]}"; exit 0; fi

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
    echo "$pair fail $((SECONDS - t0))s"
  fi
}
export -f run_one
export dir attr LOGDIR

results=$(printf '%s\n' "${pairs[@]}" | xargs -P "$jobs" -I{} bash -c 'run_one "$1"' _ {})

echo
printf '%-44s %-6s %-6s %s\n' VARIANT RESULT EXPECT DETAIL
bad=0
while read -r pair res secs rest; do
  [ -n "$pair" ] || continue
  h=${pair%%/*} v=${pair#*/}
  log="$LOGDIR/${h}__${v}.log"
  want=$(jq -r --arg v "$v" '.variants[$v].expect | if type == "object" then "fail" else . end' <<<"$info")
  msg=$(jq -r --arg v "$v" '.variants[$v].expect.fail? // ""' <<<"$info")
  shown=$want
  if [ "$attr" = matrixWithEmacs ] && [ "$want" = pass ]; then shown="pass?"; fi
  mark="" detail=$rest
  if [ "$res" = fail ]; then
    # The most useful lines of a nix error: the failed assertions, or the last "error:".
    detail=$(grep -E '^ *- |^ *error: *[^ ]' "$log" | tail -2 | tr '\n' ' ' | cut -c1-200)
  fi
  case "$want" in
    pass)
      if [ "$res" != pass ] && [ "$attr" = matrix ]; then mark=" <-- UNEXPECTED"; bad=1; fi
      if [ "$res" = pass ] && [ "$attr" = matrixWithEmacs ] && [ "$v" = host ]; then
        real=$(nix eval --raw "${nixopts[@]}" "$dir#nixosConfigurations.\"$h\".config.system.build.toplevel.drvPath" 2>>"$log")
        if [ "$real" = "$rest" ]; then detail="$rest (= nixosConfigurations.$h)"; else
          detail="$rest != nixosConfigurations.$h $real"; mark=" <-- SELF-CHECK"; bad=1; fi
      fi
      ;;
    fail)
      if [ "$res" != fail ]; then
        mark=" <-- UNEXPECTED (should fail: $msg)"; bad=1
      elif grep -qF -- "$msg" "$log"; then
        detail="as expected: $msg"
      else
        mark=" <-- FAILED FOR ANOTHER REASON (expected: $msg)"; bad=1
      fi
      ;;
  esac
  printf '%-44s %-6s %-6s %s%s\n' "$pair" "$res" "$shown" "$secs $detail" "$mark"
done < <(sort <<<"$results")
echo
echo "logs: $LOGDIR"
exit $bad
