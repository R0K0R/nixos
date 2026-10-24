# nix-guest-overlay USER UID GID BASE LOWER_ROOT QUOTA
#
# Mount USER's overlay store at BASE/.merged/USER (pam_namespace binds it over
# /nix/store in that user's sessions), on the newest frozen lower layer,
# after rebasing the upper layer onto it. Run as root by
# nix-guest-overlay-USER.service.
#
# Layout of BASE/USER (its own btrfs subvolume, the unit of quota):
#   lower/nix   read-only bind of the snapshot this overlay uses
#   upper/      overlay upper layer = the guest's own store objects
#   work/       overlay workdir
#   state/      the guest's Nix state (db, gcroots, profiles' roots), theirs
#   lower.id    which snapshot lower/nix is

set -euo pipefail
u=$1 uid=$2 gid=$3 base=$4 lroot=$5 quota=${6:-}
d=$base/$u merged=$base/.merged/$u

die() { echo "nix-guest-overlay[$u]: $*" >&2; exit 1; }

cur=$(readlink "$lroot/current") || die "no lower snapshot yet ($lroot/current)"
new=$lroot/$cur
[ -d "$new/store" ] || die "$new has no store"

# NEVER remount under a live guest: their processes keep the old overlay
# alive in their own namespaces, and two overlays on one upper directory
# corrupt it. The rebase waits for a moment with nothing of theirs running
# (logout -> user@UID stop -> this unit again).
if mountpoint -q "$merged"; then
  [ "$(cat "$d/lower.id" 2>/dev/null || true)" = "$cur" ] && exit 0
  if [ -n "$(ps -o pid= -u "$uid" 2>/dev/null)" ]; then
    echo "nix-guest-overlay[$u]: processes alive, staying on $(cat "$d/lower.id")" >&2
    exit 0
  fi
  umount "$merged"
fi
if mountpoint -q "$d/lower/nix"; then umount "$d/lower/nix"; fi

if ! btrfs subvolume show "$d" >/dev/null 2>&1; then
  [ -e "$d" ] && die "$d exists but is not a btrfs subvolume"
  btrfs subvolume create "$d" >/dev/null
fi
if [ -n "$quota" ]; then
  btrfs qgroup show "$d" >/dev/null 2>&1 || btrfs quota enable "$d"
  btrfs qgroup limit "$quota" "$d"
fi

chown root:root "$d"
chmod 0755 "$d"
install -d -m 0755 -o root -g root "$d/lower" "$d/lower/nix"
# The merged /nix/store root takes the upper root's attributes: root-owned,
# sticky and group-writable, like a normal multi-user store. The guest can
# add store objects, and cannot rename or delete the lower layer's (which are
# root's) -- the sticky bit is what keeps them from shadowing a path the
# system's own processes might later resolve in this view.
install -d -m 1775 -o root -g "$gid" "$d/upper"
install -d -m 0700 -o root -g root "$d/work"
install -d -m 0700 -o "$uid" -g "$gid" "$d/state"
install -d -m 0000 -o root -g root "$merged"

old=$(cat "$d/lower.id" 2>/dev/null || true)
db=$d/state/db/db.sqlite
if [ -n "$old" ] && [ "$old" != "$cur" ] && [ -f "$db" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  names() { sed 's|^/nix/store/||' | sort -u; }
  sqlite3 -readonly "$db" 'SELECT path FROM ValidPaths' | names >"$tmp/guest"
  sqlite3 -readonly "file:$new/var/nix/db/db.sqlite?immutable=1" 'SELECT path FROM ValidPaths' | names >"$tmp/lower"
  ls -A "$d/upper" | sort -u >"$tmp/upper"

  # Now in the lower layer too: the system's copy wins (an upper directory
  # would MERGE with a lower one of the same name). Same name, same content
  # for content-addressed paths; for input-addressed ones the guest simply
  # gets the system's build -- never the other way round.
  comm -12 "$tmp/upper" "$tmp/lower" | while IFS= read -r e; do
    rm -rf --one-file-system -- "${d:?}/upper/$e"
  done

  # Gone from the lower layer (the system garbage-collected it) but still in
  # the guest's closure: copy it up from the old snapshot. --reflink: same
  # filesystem, so this shares extents instead of copying data.
  comm -23 "$tmp/guest" "$tmp/lower" | comm -23 - "$tmp/upper" | while IFS= read -r e; do
    if [ -e "$lroot/$old/store/$e" ]; then
      cp -a --reflink=auto -- "$lroot/$old/store/$e" "$d/upper/$e"
    else
      echo "nix-guest-overlay[$u]: /nix/store/$e is in the guest's database but in neither layer" >&2
    fi
  done
fi

# THE LOWER LAYER IS ALIVE, as far as the guest's GC is concerned. Nix's
# local-overlay GC walks the merged store directory, lower entries included,
# and the guest's roots do not keep the system's paths alive: it "deletes"
# them (a no-op on the lower layer), trips over their lower referrers
# ("BUG: cannot delete path ... in use") and fails (found by
# tests/guest-overlay-vm.nix). So the snapshot's top paths -- those no other
# path refers to, whose closures are the whole snapshot -- are roots in the
# guest's state, root-owned, rewritten on every mount.
roots=$d/state/gcroots/nix-guest-lower
install -d -m 0755 -o "$uid" -g "$gid" "$d/state/gcroots"
rm -rf --one-file-system -- "$roots"
install -d -m 0755 -o root -g root "$roots"
sqlite3 -readonly "file:$new/var/nix/db/db.sqlite?immutable=1" \
  'SELECT path FROM ValidPaths WHERE id NOT IN (SELECT reference FROM Refs WHERE referrer <> reference)' |
  while IFS= read -r p; do ln -s "$p" "$roots/${p##*/}"; done

mount --bind "$new" "$d/lower/nix"
mount -o remount,bind,ro "$d/lower/nix"
mount -t overlay overlay \
  -o "lowerdir=$d/lower/nix/store,upperdir=$d/upper,workdir=$d/work,nosuid,nodev,index=off,redirect_dir=off,metacopy=off" \
  "$merged"
echo "$cur" >"$d/lower.id"
