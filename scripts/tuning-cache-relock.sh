#!/usr/bin/env bash
# tuning-cache-relock.sh -- by hand, by the admin, after users (or root)
# refreshed tuning caches (docs/multiuser-design.md, "Every user feeds the
# classifier"):
#
#   1. check       this host's users/*.nix: each owned by the user it is named
#                  after (or root) and readable -- the users directory is
#                  sticky and world-writable, so anyone can CREATE any name
#                  in it, and ownership is the one thing locking erases
#   2. gather      every other migrated host's /var/lib/tuning-cache/<host>,
#                  over ssh, into this machine's mirror at the same path (the
#                  lock is one file for every host), keeping only user files
#                  their owner wrote. A host ssh cannot reach keeps its last
#                  gathered mirror, and says so
#   3. relock      nix flake update tuning-cache-<host>... for the MIGRATED
#                  inputs (flake.nix points them at /var/lib); in-repo ones
#                  travel with the commit and have nothing to relock
#   4. roots       a GC root per locked cache path, here and on every host
#                  distributed to. Nothing else references them: the caches
#                  are read at evaluation and appear in no output, so the
#                  first GC after a relock would delete them, and the next
#                  evaluation -- with the directory changed by then -- would
#                  fail with a NAR hash mismatch
#   5. distribute  nix flake archive --to every other reachable managed
#                  host, so a host whose directory changed since (users keep
#                  writing) still evaluates the locked content. (Measured,
#                  Nix 2.35: a locked path: input whose store path is valid
#                  is used as is, even with the directory changed or gone.)
#
# Run on the machine that reaches every other host (galaxybook4-pro360: it
# has no sshd, so it gathers and nobody gathers from it). Commit flake.lock
# afterwards -- this script does not commit.
#
# usage: scripts/tuning-cache-relock.sh [-n|--dry-run] [--no-gather] [--no-distribute]
#   --dry-run  checks and gathers into a scratch directory, writes the would-be
#              lock to a temp file and diffs it; no mirror, flake.lock, root or
#              remote store is touched
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
gather=1 distribute=1 dry=0
for a in "$@"; do
  case $a in
    --no-gather) gather=0 ;;
    --no-distribute) distribute=0 ;;
    -n | --dry-run) dry=1 ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done
die() { echo "tuning-cache-relock: $*" >&2; exit 1; }
ssh_ok() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$1" true 2>/dev/null; }

self=$(hostname)
# TUNING_CACHE_ROOT: for trying this against a scratch copy (tests, dry runs).
root=${TUNING_CACHE_ROOT:-/var/lib/tuning-cache}
hosts=$(nix eval --raw --impure --expr '
  let
    f = builtins.getFlake (toString ./.);
    r = f.registry;
  in builtins.concatStringsSep " " (builtins.filter (h: (r.hosts.features.${h}.managed or false) && f.inputs ? "tuning-cache-${h}") (builtins.attrNames r.hosts.hosts))')

migrated=() inrepo=()
for h in $hosts; do
  if grep -q "url = \"path:$root/$h\";" flake.nix; then migrated+=("$h"); else inrepo+=("$h"); fi
done
[ ${#inrepo[@]} -eq 0 ] || echo "still in the repo (nothing to relock): ${inrepo[*]}"
[ ${#migrated[@]} -gt 0 ] || die "no tuning-cache input points at $root yet: run scripts/tuning-cache-migrate.sh first"

# owner_filter: read "OWNER MODE NAME" lines, print the NAMEs that may count;
# report the rest on stderr.
owner_filter() {
  local host=$1 owner mode name
  while read -r owner mode name; do
    if [ "$owner" != "${name%.nix}" ] && [ "$owner" != root ]; then
      echo "  $host: users/$name is owned by $owner, not ${name%.nix} -- skipped (remove it)" >&2
    elif (((8#$mode & 8#044) != 8#044)); then
      echo "  $host: users/$name is mode $mode, not readable by everyone -- skipped (tuning-refresh writes 0644)" >&2
    else
      echo "$name"
    fi
  done
}
list_users='find '"$root"'/%s/users -maxdepth 1 -type f -name "*.nix" -printf "%%u %%m %%f\n" 2>/dev/null'

if printf '%s\n' "${migrated[@]}" | grep -qx "$self"; then
  echo "== check $root/$self/users"
  # shellcheck disable=SC2059
  all=$(sh -c "$(printf "$list_users" "$self")" | wc -l)
  # shellcheck disable=SC2059
  ok=$(sh -c "$(printf "$list_users" "$self")" | owner_filter "$self" | wc -l)
  # This directory is locked as it is, so a bad file here cannot be filtered
  # out by copying: refuse, and leave the removal to the admin.
  [ "$ok" = "$all" ] || die "fix the files above in $root/$self/users, then run this again"
  echo "  $all user file(s), all owned by their user"
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
reachable=()
if [ "$gather" = 1 ]; then
  for h in "${migrated[@]}"; do
    [ "$h" = "$self" ] && continue
    if ! ssh_ok "$h"; then
      echo "== gather $h: NO ssh route -- locking its last gathered mirror"
      continue
    fi
    reachable+=("$h")
    echo "== gather $h"
    t=$scratch/$h
    mkdir -p "$t/users"
    rsync -a --exclude users "$h:$root/$h/" "$t/"
    # shellcheck disable=SC2059
    ssh -o BatchMode=yes "$h" "$(printf "$list_users" "$h")" | owner_filter "$h" >"$t/.keep" || true
    if [ -s "$t/.keep" ]; then
      rsync -a --files-from="$t/.keep" "$h:$root/$h/users/" "$t/users/"
    fi
    echo "  $(wc -l <"$t/.keep") user file(s)"
    rm -f "$t/.keep"
    if [ "$dry" = 1 ]; then
      diff -r "$root/$h" "$t" || true
    else
      sudo rsync -a --delete --chown=root:root --chmod=D755,F644 "$t/" "$root/$h/"
    fi
  done
fi

inputs=()
for h in "${migrated[@]}"; do inputs+=("tuning-cache-$h"); done
if [ "$dry" = 1 ]; then
  echo "== relock (dry run: into a temp lock file)"
  nix flake update "${inputs[@]}" --output-lock-file "$scratch/flake.lock"
  diff <(jq -S . flake.lock) <(jq -S . "$scratch/flake.lock") || true
  echo "dry run: nothing written"
  exit 0
fi

echo "== relock"
nix flake update "${inputs[@]}"
git --no-pager diff --stat -- flake.lock

# Store path of each locked cache, by input name (archive --json without --to
# only prints, and makes sure each is in this store).
paths=$(nix flake archive --json . | jq -r '.inputs | to_entries[] | select(.key | startswith("tuning-cache-")) | "\(.key) \(.value.path)"')
echo "== GC roots here (/nix/var/nix/gcroots/tuning-cache)"
sudo install -d -m 0755 /nix/var/nix/gcroots/tuning-cache
while read -r i p; do
  printf '%s\n' "${inputs[@]}" | grep -qx "$i" || continue
  sudo nix-store --add-root "/nix/var/nix/gcroots/tuning-cache/$i" --realise "$p" >/dev/null
  echo "  $i -> $p"
done <<<"$paths"

if [ "$distribute" = 1 ]; then
  for h in $hosts; do
    [ "$h" = "$self" ] && continue
    printf '%s\n' "${reachable[@]}" | grep -qx "$h" || ssh_ok "$h" || { echo "== distribute to $h: no ssh route, skipped"; continue; }
    echo "== distribute to $h"
    nix flake archive --to "ssh-ng://$h" .
    # The admin's own indirect roots there (no root over ssh): GC follows
    # them through /nix/var/nix/gcroots/auto like any result symlink.
    while read -r i p; do
      printf '%s\n' "${inputs[@]}" | grep -qx "$i" || continue
      ssh -o BatchMode=yes "$h" "mkdir -p ~/.local/state/tuning-cache/gcroots && nix-store --add-root ~/.local/state/tuning-cache/gcroots/$i --realise $p >/dev/null"
    done <<<"$paths"
  done
fi
echo "done -- review and commit flake.lock (git commit -- flake.lock), then pull it on every other host's checkout"
