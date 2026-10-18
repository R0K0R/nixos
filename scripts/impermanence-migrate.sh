#!/usr/bin/env bash
# impermanence-migrate.sh -- FROM A LIVE USB, as root: convert galaxybook4-pro360's
# flat btrfs into the impermanence layout and install the prepared system.
# Read docs/impermanence-migration.md first. Dry run unless --go.
#
#   impermanence-migrate.sh /dev/disk/by-uuid/<root> [--go] [--plan DIR] [--step N]
#
# Steps (each idempotent; --step N runs one):
#   1 mount subvolid=5 at /mnt/top; read-only snapshot @pre-migration (the undo)
#   2 @nix          <- /nix            (cp --reflink=always: metadata only)
#   3 @windows-backup <- /home/<primary>/windows-backup
#   4 @persist      <- every system path in the plan, and per user every entry
#                      of user-<name>.json under @persist/home/<name>/, plus
#                      user-<name>.persist.json as .persist.json
#   5 @swap         (empty; NixOS creates /swap/swapfile at first boot)
#   6 @root-blank   (empty, read-only) and @root from it
#   7 mount the new layout at /mnt/new and nixos-install the prepared toplevel
# The old tree (subvolid 5's own folders: /home, /nix, /etc, ...) is left in
# place, untouched: delete it only after the new system has booted and been
# checked (the doc's last section).
set -euo pipefail

dev=${1:?usage: impermanence-migrate.sh <btrfs device> [--go] [--plan DIR] [--step N]}
shift
go=0 step="" plan=""
while [ $# -gt 0 ]; do
  case $1 in
    --go) go=1 ;;
    --plan) plan=$2; shift ;;
    --step) step=$2; shift ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ "$(id -u)" = 0 ] || { echo "run as root (from the live USB)" >&2; exit 1; }

top=/mnt/top new=/mnt/new
primary=r0k0r
run() { echo "+ $*"; [ "$go" = 1 ] && "$@"; return 0; }
want() { [ -z "$step" ] || [ "$step" = "$1" ]; }
# copy SRC to DEST keeping everything; refuse to overwrite; verify by listing
copy() {
  local src=$1 dst=$2
  [ -e "$src" ] || [ -L "$src" ] || { echo "  (absent) $src"; return 0; }
  [ -e "$dst" ] && { echo "  (exists) $dst"; return 0; }
  run mkdir -p "$(dirname "$dst")"
  run cp -a --reflink=always "$src" "$dst"
  if [ "$go" = 1 ]; then
    a=$(cd "$src" 2>/dev/null && find . | sort | sha256sum || stat -c '%s %Y' "$src")
    b=$(cd "$dst" 2>/dev/null && find . | sort | sha256sum || stat -c '%s %Y' "$dst")
    [ "$a" = "$b" ] || { echo "VERIFY FAILED: $src -> $dst" >&2; exit 1; }
  fi
}
subvol() { [ -d "$top/$1" ] && echo "  (exists) @${1#@}" || run btrfs subvolume create "$top/$1"; }

mkdir -p "$top"
mountpoint -q "$top" || run mount -t btrfs -o subvolid=5 "$dev" "$top"
plan=${plan:-$top/home/$primary/impermanence-plan}
[ -f "$plan/system-dirs.txt" ] || { echo "no plan at $plan (run scripts/impermanence-prepare.sh on the machine first)" >&2; exit 1; }
toplevel=$(cat "$plan/toplevel")

if want 1; then
  echo "== 1 undo snapshot"
  [ -d "$top/@pre-migration" ] && echo "  (exists) @pre-migration" || run btrfs subvolume snapshot -r "$top" "$top/@pre-migration"
fi
if want 2; then
  echo "== 2 @nix"
  if [ -d "$top/@nix/store" ]; then echo "  (exists) @nix"; else subvol @nix; copy "$top/nix/store" "$top/@nix/store"; copy "$top/nix/var" "$top/@nix/var"; fi
fi
if want 3; then
  echo "== 3 @windows-backup"
  if [ -d "$top/@windows-backup" ]; then echo "  (exists)"; else
    subvol @windows-backup
    [ -d "$top/home/$primary/windows-backup" ] && run cp -a --reflink=always "$top/home/$primary/windows-backup/." "$top/@windows-backup/"
  fi
fi
if want 4; then
  echo "== 4 @persist"
  subvol @persist
  while IFS= read -r p; do [ -n "$p" ] && copy "$top$p" "$top/@persist$p"; done <"$plan/system-dirs.txt"
  while IFS= read -r p; do [ -n "$p" ] && copy "$top$p" "$top/@persist$p"; done <"$plan/system-files.txt"
  for f in "$plan"/user-*.json; do
    case $f in *.persist.json | *.system.json) continue ;; esac
    u=$(basename "$f" .json); u=${u#user-}
    uid=$(stat -c %u "$top/home/$u") gid=$(stat -c %g "$top/home/$u")
    run install -d -m 0700 -o "$uid" -g "$gid" "$top/@persist/home" "$top/@persist/home/$u"
    run chmod 0755 "$top/@persist/home"
    jq -r '.directories[], .files[]' "$f" | while IFS= read -r p; do
      copy "$top/home/$u/$p" "$top/@persist/home/$u/$p"
    done
    run install -m 0644 -o "$uid" -g "$gid" "$plan/user-$u.persist.json" "$top/@persist/home/$u/.persist.json"
  done
fi
if want 5; then
  echo "== 5 @swap"
  subvol @swap
  run chattr +C "$top/@swap"
fi
if want 6; then
  echo "== 6 @root-blank, @root"
  if [ ! -d "$top/@root-blank" ]; then subvol @root-blank; run btrfs property set -ts "$top/@root-blank" ro true; fi
  [ -d "$top/@root" ] && echo "  (exists) @root" || run btrfs subvolume snapshot "$top/@root-blank" "$top/@root"
fi
if want 7; then
  echo "== 7 install $toplevel"
  [ -e "$top/@nix/store/${toplevel#/nix/store/}" ] || { echo "the prepared toplevel is not in @nix/store -- was it built (prepare script) before step 2?" >&2; exit 1; }
  run mkdir -p "$new"
  mountpoint -q "$new" || run mount -t btrfs -o subvol=@root "$dev" "$new"
  for m in nix:@nix persist:@persist swap:@swap; do
    run mkdir -p "$new/${m%%:*}"
    mountpoint -q "$new/${m%%:*}" || run mount -t btrfs -o "subvol=${m#*:}" "$dev" "$new/${m%%:*}"
  done
  echo "  mount the EFI partition at $new/boot yourself (lsblk -f: the vfat one, UUID DFF1-0A5E) -- then rerun --step 7"
  mountpoint -q "$new/boot" && run nixos-install --root "$new" --system "$toplevel" --no-root-passwd --no-channel-copy
fi
[ "$go" = 1 ] && echo "done" || echo "dry run -- add --go"
