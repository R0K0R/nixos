#!/usr/bin/env bash
# tuning-cache-relock.sh -- by hand, by the admin, after users (or root)
# refreshed tuning caches (docs/multiuser-design.md, "Every user feeds the
# classifier"):
#
#   1. gather      copy every other host's /var/lib/tuning-cache/<host> here,
#                  to the same path (the lock is one file for every host)
#   2. relock      nix flake update tuning-cache-<host>... in the system repo
#   3. distribute  nix flake archive --to each other host, so a host whose
#                  directory changed since (users keep writing) still has the
#                  locked content in its store and evaluates
#
# Run on a machine that can ssh to every other host (galaxybook4-pro360: it has
# no sshd, so it gathers and nobody gathers from it). Commit flake.lock
# afterwards -- this script does not commit.
#
# usage: scripts/tuning-cache-relock.sh [--no-gather] [--no-distribute]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
gather=1 distribute=1
for a in "$@"; do
  case $a in
    --no-gather) gather=0 ;;
    --no-distribute) distribute=0 ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done

self=$(hostname)
hosts=$(nix eval --raw --impure --expr '
  let r = (builtins.getFlake (toString ./.)).registry;
  in builtins.concatStringsSep " " (builtins.filter (h: r.hosts.features.${h}.managed or false) (builtins.attrNames r.hosts.hosts))')

for h in $hosts; do
  url=$(nix flake metadata --json . | jq -r --arg i "tuning-cache-$h" '.locks.nodes[$i].original.path // empty')
  case $url in
    /var/lib/tuning-cache/*) ;;
    *) echo "tuning-cache-$h still points at the repo ($url): run scripts/tuning-cache-migrate.sh first" >&2; exit 1 ;;
  esac
done

if [ "$gather" = 1 ]; then
  for h in $hosts; do
    [ "$h" = "$self" ] && continue
    echo "== gather $h"
    tmp=$(mktemp -d)
    rsync -a --delete "$h:/var/lib/tuning-cache/$h/" "$tmp/"
    sudo rsync -a --delete --chown=root:root --exclude users "$tmp/" "/var/lib/tuning-cache/$h/"
    sudo rsync -a --delete "$tmp/users/" "/var/lib/tuning-cache/$h/users/"
    rm -rf "$tmp"
  done
fi

echo "== relock"
inputs=$(for h in $hosts; do printf 'tuning-cache-%s ' "$h"; done)
# shellcheck disable=SC2086
nix flake update $inputs
git --no-pager diff --stat -- flake.lock

if [ "$distribute" = 1 ]; then
  for h in $hosts; do
    [ "$h" = "$self" ] && continue
    echo "== distribute to $h"
    nix flake archive --to "ssh-ng://$h" .
  done
fi
echo "done -- review and commit flake.lock (git commit flake.lock)"
