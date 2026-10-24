#!/usr/bin/env bash
# The per-user tuning scripts' decisions that need no evaluation and no root
# (docs/multiuser-design.md, "Running the migration"):
#   - cache-dir.sh: where a host's cache is written, decided by flake.lock
#     (in the repo / migrated here / migrated elsewhere = skip / missing = error)
#   - tuning-refresh: no home repo = exit 2 (root's --all skips it); no cache
#     directory = refused unless --print
#   - every script parses
# The full dry runs (tuning-refresh --print against a real home, the migrate
# and relock --dry-run against a scratch copy with TUNING_CACHE_ROOT) evaluate
# real flakes and are described in the design doc, not run here.
# usage: tests/user-tuning-scripts.sh [flake-dir]
set -euo pipefail
dir=$(cd "${1:-$(dirname "$0")/..}" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for s in "$dir"/tuning/runtime-cache/*.sh "$dir"/scripts/tuning-cache-*.sh; do
  bash -n "$s" || fail "$s does not parse"
done
echo "ok   scripts parse"

# -- cache_dir ----------------------------------------------------------------
self=$(hostname)
mkdir -p "$t/here"
jq -n --arg self "$self" --arg here "$t/here" '{nodes: {
  ("tuning-cache-" + $self): {original: {type: "path", path: $here}},
  "tuning-cache-inrepo": {original: {type: "path", path: "./tuning/runtime-cache/hosts/inrepo"}},
  "tuning-cache-elsewhere": {original: {type: "path", path: "/var/lib/tuning-cache/elsewhere"}}
}}' >"$t/flake.lock"
cd_rc() {
  local out rc=0
  out=$(FLAKE_ROOT=$t bash -c '. "$1"; cache_dir "$2"' _ "$dir/tuning/runtime-cache/cache-dir.sh" "$1" 2>/dev/null) || rc=$?
  echo "$rc${out:+ $out}"
}
[ "$(cd_rc inrepo)" = "0 $t/tuning/runtime-cache/hosts/inrepo" ] || fail "in-repo input: $(cd_rc inrepo)"
[ "$(cd_rc "$self")" = "0 $t/here" ] || fail "migrated input of this host: $(cd_rc "$self")"
[ "$(cd_rc elsewhere)" = 3 ] || fail "another host's migrated input should be skipped (3): $(cd_rc elsewhere)"
rmdir "$t/here"
[ "$(cd_rc "$self")" = 4 ] || fail "this host's migrated input without its directory should be an error (4): $(cd_rc "$self")"
echo "ok   cache_dir: in repo / migrated here / elsewhere skipped / missing refused"

# -- tuning-refresh -------------------------------------------------------------
refresh() { SYSTEM_FLAKE=$dir TUNING_CACHE_DIR=$t/cache bash -uo pipefail "$dir/tuning/runtime-cache/tuning-refresh.sh" "$@"; }
rc=0; HM_REPO=$t/no-such-repo refresh --print 2>/dev/null >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "tuning-refresh without a home repo should exit 2, got $rc"
rc=0; HM_REPO=$t/no-such-repo refresh 2>/dev/null >/dev/null || rc=$?
[ "$rc" = 1 ] || fail "tuning-refresh without a cache directory should be refused (1), got $rc"
rc=0; refresh --user nobody 2>/dev/null >/dev/null || rc=$?
[ "$(id -u)" = 0 ] || [ "$rc" = 1 ] || fail "tuning-refresh --user as non-root should be refused, got $rc"
echo "ok   tuning-refresh: no repo = 2, no directory = refused, --user is root's"
