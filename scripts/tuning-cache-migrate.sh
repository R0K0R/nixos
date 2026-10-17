#!/usr/bin/env bash
# tuning-cache-migrate.sh -- ONE TIME: move the tuning classifier's caches out
# of the repo (tuning/runtime-cache/hosts/<host>) to plain directories,
# /var/lib/tuning-cache/<host>, and point the flake's tuning-cache-<host>
# inputs at them (docs/multiuser-design.md, "Every user feeds the classifier").
#
# Before: my.tuning.userCache.enable = true on every host, switched (it creates
# /var/lib/tuning-cache/<host>/users, writable by every user, and installs
# tuning-refresh).
#
# Run ON EACH HOST once (it seeds that host's own directory, which is where its
# users write), then on the relocking machine with --switch-inputs, which also
# seeds every other host's directory there, rewrites the two input URLs in
# flake.nix and runs scripts/tuning-cache-relock.sh.
#
# usage: scripts/tuning-cache-migrate.sh [--switch-inputs]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
self=$(hostname)
hosts=$(nix eval --raw --impure --expr '
  let r = (builtins.getFlake (toString ./.)).registry;
  in builtins.concatStringsSep " " (builtins.filter (h: r.hosts.features.${h}.managed or false) (builtins.attrNames r.hosts.hosts))')

seed() {
  local h=$1 src=tuning/runtime-cache/hosts/$1 dst=/var/lib/tuning-cache/$1
  sudo install -d -m 0755 -o root -g root /var/lib/tuning-cache "$dst"
  sudo install -d -m 1777 -o root -g root "$dst/users"
  for f in "$src"/system-tier1.nix "$src"/system-tier2.nix; do
    [ -e "$f" ] && [ ! -e "$dst/$(basename "$f")" ] && sudo install -m 0644 -o root -g root "$f" "$dst/"
  done
  echo "seeded $dst"
}

if [ "${1:-}" != --switch-inputs ]; then
  seed "$self"
  echo "now run this with --switch-inputs on the relocking machine"
  exit 0
fi

for h in $hosts; do seed "$h"; done
for h in $hosts; do
  sed -i "s|url = \"path:./tuning/runtime-cache/hosts/$h\";|url = \"path:/var/lib/tuning-cache/$h\";|" flake.nix
done
git --no-pager diff -- flake.nix
exec scripts/tuning-cache-relock.sh
