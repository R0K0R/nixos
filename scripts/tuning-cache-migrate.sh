#!/usr/bin/env bash
# tuning-cache-migrate.sh -- ONE TIME (re-runnable): move the tuning
# classifier's caches out of the repo (tuning/runtime-cache/hosts/<host>) to
# plain directories, /var/lib/tuning-cache/<host>, and point the flake's
# tuning-cache-<host> inputs at them (docs/multiuser-design.md, "Every user
# feeds the classifier", and "Running the migration" there for the order).
#
#   seed                    (default) on EACH host: put this checkout's copy
#                           of the host's system-tier{1,2}.nix into
#                           /var/lib/tuning-cache/<this host>, never over an
#                           existing file
#   --switch-inputs [HOST]  on the relocking machine (galaxybook4-pro360: it
#                           reaches every other host, nobody reaches it): make
#                           the mirrors of the named hosts (default: this one
#                           and every other managed host ssh reaches), rewrite
#                           their input URLs in flake.nix, then hand over to
#                           scripts/tuning-cache-relock.sh (gather, relock,
#                           GC roots, distribute)
#   -n | --dry-run          print what would be done, change nothing
#
# Idempotent: seeding skips files that exist, the URL rewrite matches only
# the in-repo form, the relock is a relock. Safe to re-run after a failure
# at any step.
#
# Before: my.tuning.userCache.enable = true on the host, SWITCHED. That
# creates /var/lib/tuning-cache/<host>/users (sticky, world-writable) and,
# on an impermanent host, the bind mount from /persist that makes anything
# written there survive a reboot. Seeding without it would write into the
# tmpfs root on galaxybook4-pro360 and lose the files at the next boot -- so
# both are checked, not assumed.
#
# Needs sudo (seeding and the mirrors are root's). Never evaluates anything
# as root.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
dry=0 mode=seed
sel=()
while [ $# -gt 0 ]; do
  case $1 in
    -n | --dry-run) dry=1 ;;
    --switch-inputs) mode=switch ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
    -*) echo "unknown argument $1" >&2; exit 2 ;;
    *) [ "$mode" = switch ] || { echo "a host list is for --switch-inputs" >&2; exit 2; }; sel+=("$1") ;;
  esac
  shift
done

die() { echo "tuning-cache-migrate: $*" >&2; exit 1; }
run() {
  if [ "$dry" = 1 ]; then echo "  would: $*"; else "$@"; fi
}

self=$(hostname)
# TUNING_CACHE_ROOT: for trying this against a scratch copy (tests, dry runs).
root=${TUNING_CACHE_ROOT:-/var/lib/tuning-cache}
# host -> "managed impermanence" for every host that has a tuning-cache input.
facts=$(nix eval --raw --impure --expr '
  let
    f = builtins.getFlake (toString ./.);
    r = f.registry;
    hs = builtins.filter (h: (r.hosts.features.${h}.managed or false) && f.inputs ? "tuning-cache-${h}") (builtins.attrNames r.hosts.hosts);
  in builtins.concatStringsSep "\n" (map (h: "${h} ${if r.hosts.features.${h}.impermanence or false then "1" else "0"}") hs)')
hosts=$(cut -d' ' -f1 <<<"$facts")
impermanent() { [ "$(awk -v h="$1" '$1 == h { print $2 }' <<<"$facts")" = 1 ]; }
grep -qx "$self" <<<"$hosts" || die "$self has no tuning-cache input in flake.nix"

# The checks that make seeding this host meaningful (see the header).
check_self() {
  local d=$root/$self
  [ -d "$d/users" ] && [ "$(stat -c %a "$d/users")" = 1777 ] \
    || die "$d/users is missing or not mode 1777: set my.tuning.userCache.enable = true for $self and switch first"
  # (Only for the real path: a TUNING_CACHE_ROOT scratch copy is not what
  # my.state persists.)
  if impermanent "$self" && [ "$root" = /var/lib/tuning-cache ]; then
    findmnt -rn -M "$root" >/dev/null \
      || die "$self is impermanent but $root is not a mount: the userCache switch has not taken effect (my.state.system.state, reboot or start the mount unit), and anything written now would vanish at the next boot"
  fi
}

seed_self() {
  local src=tuning/runtime-cache/hosts/$self dst=$root/$self f n=0
  echo "== seed $dst from $src"
  for f in "$src"/system-tier1.nix "$src"/system-tier2.nix; do
    [ -e "$f" ] || continue
    if [ -e "$dst/$(basename "$f")" ]; then
      echo "  $(basename "$f"): already there, kept"
    else
      run sudo install -m 0644 -o root -g root "$f" "$dst/"
      n=$((n + 1))
    fi
  done
  if [ "$dry" = 1 ]; then echo "  $n file(s) would be seeded"; else echo "  $n file(s) seeded"; fi
}

if [ "$mode" = seed ]; then
  check_self
  seed_self
  echo "next: on the relocking machine, scripts/tuning-cache-migrate.sh --switch-inputs (after every host is seeded)"
  exit 0
fi

# -- --switch-inputs -----------------------------------------------------------
[ ${#sel[@]} -gt 0 ] || mapfile -t sel <<<"$hosts"
check_self
seed_self
todo=()
for h in "${sel[@]}"; do
  grep -qx "$h" <<<"$hosts" || die "$h is not a managed host with a tuning-cache input"
  if [ "$h" = "$self" ]; then
    todo+=("$h")
    continue
  fi
  # A host must be seeded ON ITSELF before its input moves: the gather
  # replaces this machine's mirror with whatever is there, and an unseeded
  # directory would lock an empty cache for it (all of its tuning falls back
  # to Tier 3, silently).
  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" true 2>/dev/null; then
    echo "== $h: no ssh route from $self -- its input stays in the repo"
    continue
  fi
  # (an untuned host has no system files to seed, only users/)
  want="test -d $root/$h/users"
  compgen -G "tuning/runtime-cache/hosts/$h/system-tier*.nix" >/dev/null \
    && want="$want && ls $root/$h/system-tier*.nix"
  ssh -o BatchMode=yes "$h" "$want" >/dev/null 2>&1 \
    || die "$h is reachable but not seeded: run scripts/tuning-cache-migrate.sh on $h first"
  echo "== mirror $root/$h (root's, 0755 throughout: only the gather writes it)"
  run sudo install -d -m 0755 -o root -g root "$root/$h" "$root/$h/users"
  todo+=("$h")
done
[ ${#todo[@]} -gt 0 ] || die "no host to switch"

echo "== flake.nix: ${todo[*]} -> $root/<host>"
for h in "${todo[@]}"; do
  if grep -q "url = \"path:$root/$h\";" flake.nix; then
    echo "  $h: already switched"
  elif [ "$dry" = 1 ]; then
    echo "  would rewrite url = \"path:./tuning/runtime-cache/hosts/$h\" -> \"path:$root/$h\""
  else
    sed -i "s|url = \"path:./tuning/runtime-cache/hosts/$h\";|url = \"path:$root/$h\";|" flake.nix
    grep -q "url = \"path:$root/$h\";" flake.nix || die "could not rewrite the tuning-cache-$h URL in flake.nix"
  fi
done
[ "$dry" = 1 ] || git --no-pager diff -- flake.nix
if [ "$dry" = 1 ]; then
  echo "would run: scripts/tuning-cache-relock.sh (its own dry run needs the URLs switched first)"
  exit 0
fi
exec scripts/tuning-cache-relock.sh
