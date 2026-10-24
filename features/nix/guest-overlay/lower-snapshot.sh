# nix-guest-lower-snapshot LOWER_ROOT BASE GUEST...
#
# Take a new frozen lower layer for the guests' overlay stores: a read-only
# btrfs snapshot of /nix (store and database at one point in time), made
# self-consistent, then published as LOWER_ROOT/current. Old snapshots are
# deleted once no mounted guest overlay uses them. Guests are then asked to
# rebase (their unit refuses while any of their processes is alive).
#
# Run as root by nix-guest-lower.service: at boot, and after every system
# activation (a new generation's paths must be visible to new guest sessions).

set -euo pipefail
lroot=$1 base=$2
shift 2

die() { echo "nix-guest-lower: $*" >&2; exit 1; }

[ "$(stat -f -c %T /nix)" = btrfs ] || die "/nix is not on btrfs"
btrfs subvolume show /nix >/dev/null 2>&1 || die "/nix is not a btrfs subvolume (my.btrfs-layout)"
install -d -m 0755 -o root -g root "$lroot"

id=$(date -u +%Y%m%dT%H%M%SZ)-$$
new=$lroot/$id
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Writable first: the copy is only crash-consistent, and two things have to be
# fixed in it before anyone may read it.
btrfs subvolume snapshot /nix "$new" >/dev/null

# 1. The database. Nix runs SQLite in WAL mode, and a read-only lower is opened
#    with immutable=1, which never reads the WAL: fold it into the main file.
db=$new/var/nix/db/db.sqlite
sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
rm -f "$db-wal" "$db-shm"

# 2. The store directory. Anything present but not registered -- an output a
#    build was still writing, a path the GC had already invalidated, a lock
#    file -- would look to a guest's Nix like an invalid path it must delete,
#    and it cannot delete from the lower layer. A registered path is always
#    complete (Nix registers after writing and invalidates before deleting).
sqlite3 "$db" 'SELECT path FROM ValidPaths' | sed 's|^/nix/store/||' | sort -u >"$tmp/valid"
ls -A "$new/store" | sort -u >"$tmp/present"
# (grep exits 1 when nothing is left -- the usual case on a quiet store --
# which pipefail would turn into a failed snapshot: found by the VM test.)
comm -13 "$tmp/valid" "$tmp/present" | { grep -vx '.links' || true; } | while IFS= read -r e; do
  rm -rf --one-file-system -- "${new:?}/store/$e"
done

btrfs property set -ts "$new" ro true
ln -sfn "$id" "$lroot/.current.tmp"
mv -T "$lroot/.current.tmp" "$lroot/current"

# Prune: keep current and every snapshot a guest's overlay is mounted on.
keep=$id
for u in "$@"; do
  if mountpoint -q "$base/.merged/$u" && [ -s "$base/$u/lower.id" ]; then
    keep="$keep $(cat "$base/$u/lower.id")"
  fi
done
for d in "$lroot"/*/; do
  # current/ matches the glob too, and deleting through it deletes the
  # snapshot it points at -- the newest one (found by the VM test).
  [ -L "${d%/}" ] && continue
  s=$(basename "$d")
  case " $keep " in *" $s "*) continue ;; esac
  btrfs subvolume delete "$d" >/dev/null || echo "nix-guest-lower: could not delete $d" >&2
done

for u in "$@"; do
  systemctl --no-block restart "nix-guest-overlay-$u.service" || true
done
