# Runs in the systemd initrd, before / is mounted (impermanence-rollback.service).
# DEVICE, ROOT (@root), BLANK (@root-blank), KEEP (days; 0 = delete at once).
set -eu
mnt=/run/impermanence-btrfs
mkdir -p "$mnt"
mount -t btrfs -o subvolid=5 "$DEVICE" "$mnt"
trap 'umount "$mnt"' EXIT

if [ ! -d "$mnt/$BLANK" ]; then
  # Never wipe without the snapshot to restore from: a missing blank means the
  # migration was not done (docs/impermanence-migration.md), and booting the
  # old root is the only safe thing to do.
  echo "impermanence: $BLANK missing -- NOT rolling back" >&2
  exit 0
fi

# Delete a subvolume and every subvolume nested in it (machinectl, docker and
# systemd create nested ones on /var), deepest first.
delete_tree() {
  btrfs subvolume list -o "$1" | sed 's/.* path //' | sort -r | while read -r sub; do
    delete_tree "$mnt/$sub"
  done
  btrfs subvolume delete "$1" >/dev/null
}

now=$(date -u +%s)
if [ -d "$mnt/$ROOT" ]; then
  if [ "$KEEP" -gt 0 ]; then
    mkdir -p "$mnt/old-roots"
    # Named by RETIREMENT time (now), not by the root's own mtime, which can be
    # months old for a root retired today.
    stamp=$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)
    [ -e "$mnt/old-roots/$stamp" ] && stamp="$stamp-$$"
    mv "$mnt/$ROOT" "$mnt/old-roots/$stamp"
  else
    delete_tree "$mnt/$ROOT"
  fi
fi

if [ "$KEEP" -gt 0 ] && [ -d "$mnt/old-roots" ]; then
  for old in "$mnt"/old-roots/*; do
    [ -d "$old" ] || continue
    s=$(basename "$old")
    case $s in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z*) ;; *) continue ;; esac
    t=$(date -u -d "${s:0:4}-${s:4:2}-${s:6:2} ${s:9:2}:${s:11:2}:${s:13:2}" +%s) || continue
    if [ $((now - t)) -gt $((KEEP * 86400)) ]; then
      delete_tree "$old"
    fi
  done
fi

btrfs subvolume snapshot "$mnt/$BLANK" "$mnt/$ROOT" >/dev/null
