#!/usr/bin/env bash
# The select step of features/session/gl-namespace (gl-driver-select.sh), run
# directly against a scratch tree: no root, no PAM, no namespace, nothing
# built. GL_NS_STORE/GL_NS_OWNER point its "is this a store directory"
# check at a fake store owned by the caller (the Nix wrapper pins them to
# /nix/store and root).
# usage: tests/gl-namespace-select.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../features/session/gl-namespace/gl-driver-select.sh

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/store" "$t/root/inst" "$t/home/u/.local/state/nix/profiles" "$t/peruser" "$t/elsewhere/tree"
printf '#!/bin/sh\nshift 2; echo "$*" >> %s/log\n' "$t" > "$t/bin/logger"
chmod +x "$t/bin/logger"
ln -s /nowhere "$t/root/system"
ln -s /nowhere-32 "$t/root/system-32"

h() { printf '%032d' "$1" | tr 0-9 a-j; }
gen=$t/store/$(h 1)-home-manager-generation
tree=$t/store/$(h 2)-graphics-drivers
tree2=$t/store/$(h 3)-graphics-drivers
mkdir -p "$gen" "$tree" "$tree2"
profile=$t/home/u/.local/state/nix/profiles/home-manager

run() {
  env PATH="$t/bin:$PATH" GL_NS_ROOT="$t/root" GL_NS_GCROOTS="$t/gcroots" GL_NS_PERUSER="$t/peruser" \
    GL_NS_STORE="$t/store" GL_NS_OWNER="$(id -u)" GL_NS_32="${GL_NS_32:-0}" GL_NS_USERS="u other" \
    GL_NS_HOME="$t/home/$1" bash "$script" "$1"
}
link() { readlink "$t/root/inst/u/tree${1:-}"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok   $*"; }

run nobody
[ ! -e "$t/root/inst/nobody" ] || fail "unmapped user got an instance"
ok "unmapped user: nothing touched"

run u
[ "$(link)" = "$t/root/system" ] || fail "no profile: $(link)"
[ ! -e "$t/gcroots/u" ] || fail "no profile: gcroot"
ok "no generation: system tree, no gcroot"

ln -s "$gen" "$profile"
run u
[ "$(link)" = "$t/root/system" ] || fail "generation without driver: $(link)"
ok "generation without graphics-driver: system tree"

ln -s "$tree" "$gen/graphics-driver"
run u
[ "$(link)" = "$tree" ] || fail "declared driver: $(link)"
[ "$(readlink "$t/gcroots/u")" = "$tree" ] || fail "declared driver: gcroot"
ok "declared driver: user tree + gcroot"

GL_NS_32=1 run u
[ "$(link -32)" = "$t/root/system-32" ] || fail "no -32 in generation: $(link -32)"
[ "$(link)" = "$tree" ] || fail "-32 run moved the 64-bit tree"
ok "32-bit: system's 32-bit tree when the generation has none"

rm "$gen/graphics-driver"
ln -s "$t/elsewhere/tree" "$gen/graphics-driver"
run u
[ "$(link)" = "$t/root/system" ] || fail "tree outside the store accepted: $(link)"
[ ! -e "$t/gcroots/u" ] || fail "tree outside the store: stale gcroot kept"
grep -q "not a store directory" "$t/log" || fail "tree outside the store: not logged"
ok "tree outside the store: refused, logged, gcroot dropped"

rm "$gen/graphics-driver"
ln -s "$t/store/$(h 3)-graphics-drivers/." "$gen/graphics-driver"
run u
[ "$(link)" = "$tree2" ] || fail "trailing /. not normalised: $(link)"
ok "resolved path is normalised before the check"

rm "$profile"
mkdir -p "$t/elsewhere/gen"
ln -s "$tree" "$t/elsewhere/gen/graphics-driver"
ln -s "$t/elsewhere/gen" "$profile"
run u
[ "$(link)" = "$t/root/system" ] || fail "generation outside the store accepted: $(link)"
ok "generation outside the store: ignored"

rm "$profile"
mkdir -p "$t/peruser/u"
ln -s "$gen" "$t/peruser/u/home-manager"
ln -s "$tree" "$gen/graphics-driver.tmp" && mv -T "$gen/graphics-driver.tmp" "$gen/graphics-driver"
run u
[ "$(link)" = "$tree" ] || fail "legacy per-user profile: $(link)"
ok "legacy per-user profile is read"

rm -rf "$t/root/inst/u"
ln -s "$t/elsewhere" "$t/root/inst/u"
run u
[ -L "$t/root/inst/u" ] && [ ! -L "$t/elsewhere/tree" ] && [ ! -e "$t/elsewhere/.tree.new" ] || fail "symlinked instance followed"
grep -q "is not a directory; left alone" "$t/log" || fail "symlinked instance: not logged"
ok "instance that is a symlink: left alone"

echo "all passed"
