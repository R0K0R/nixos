#!/usr/bin/env bash
# impermanence-usb-session.sh -- the whole live-USB session in one go, as root.
# Dry run, a typed "yes", the migration, the EFI mount, step 7. Everything is
# logged to the OLD home (subvolid 5), so it can be read after the first boot:
#   sudo mount -o subvolid=5 /dev/disk/by-uuid/473402c5-... /mnt && less /mnt/home/r0k0r/impermanence-usb.log
#
# From the ISO:
#   sudo -i
#   mkdir -p /mnt/top && mount -t btrfs -o subvolid=5 /dev/disk/by-uuid/473402c5-fb75-4760-afee-e10d2da78f5b /mnt/top
#   bash /mnt/top/home/r0k0r/flakes/nixos-multiuser/scripts/impermanence-usb-session.sh
set -euo pipefail
dev=/dev/disk/by-uuid/473402c5-fb75-4760-afee-e10d2da78f5b
efi=/dev/disk/by-uuid/DFF1-0A5E
top=/mnt/top new=/mnt/new
[ "$(id -u)" = 0 ] || { echo "run as root (sudo -i first)" >&2; exit 1; }
mkdir -p "$top"
mountpoint -q "$top" || mount -t btrfs -o subvolid=5 "$dev" "$top"
migrate="$top/home/r0k0r/flakes/nixos-multiuser/scripts/impermanence-migrate.sh"
log=$top/home/r0k0r/impermanence-usb.log
exec > >(tee -a "$log") 2>&1

echo "== $(date -Is) dry run"
bash "$migrate" "$dev"
echo
read -rp "Read the dry run above. Type yes to run it for real: " answer
[ "$answer" = yes ] || { echo "not yes -- stopped, nothing changed"; exit 1; }

echo "== $(date -Is) migration"
bash "$migrate" "$dev" --go

echo "== $(date -Is) EFI and step 7"
mkdir -p "$new/boot"
mountpoint -q "$new/boot" || mount "$efi" "$new/boot"
bash "$migrate" "$dev" --go --step 7

echo "== $(date -Is) ~/.claude again"
# Step 4 copied ~/.claude while a USB-side Claude session (impermanence-usb-claude.sh,
# root with HOME=/home/r0k0r) may still be writing it: give the files back to r0k0r
# and copy it once more, so the new system resumes from the end of the session.
home=$top/home/r0k0r p=$top/@persist/home/r0k0r
chown -R 1000:100 "$home/.claude" "$home/.claude.json"
rm -rf "$p/.claude.new"
cp -a --reflink=always "$home/.claude" "$p/.claude.new"
rm -rf "$p/.claude" && mv "$p/.claude.new" "$p/.claude"
cp -a --reflink=always "$home/.claude.json" "$p/.claude.json"

echo "== $(date -Is) checks"
echo "system profile: $(readlink -f "$new/nix/var/nix/profiles/system")"
echo "plan toplevel:  $(cat "$top/home/r0k0r/impermanence-plan/toplevel")"
ls -1t "$new/boot/loader/entries" | head -3
btrfs subvolume list "$top" | grep -E '@(pre-migration|nix|persist|swap|root|root-blank|windows-backup)$'
sync
echo "== $(date -Is) done -- if the two paths above match, reboot"
