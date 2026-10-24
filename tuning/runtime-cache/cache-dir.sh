# Sourced by the refresh scripts. Where a host's classifier cache lives on
# THIS machine.
#
# Decided by where the flake's tuning-cache-<host> input points (flake.lock),
# NOT by whether /var/lib/tuning-cache/<host> exists. my.tuning.userCache
# creates that directory as soon as it is switched on, which is BEFORE
# scripts/tuning-cache-migrate.sh points the input at it; going by existence,
# a refresh in that window wrote the system's files where no evaluation reads
# them, reported success, and the in-repo copy the rebuild actually used
# silently aged.
#
#   in the repo   tuning/runtime-cache/hosts/<host> -- any machine may refresh
#                 any host there (Tier 2 from anywhere, Tier 1 over ssh), and
#                 the commit is what carries it
#   migrated      /var/lib/tuning-cache/<host> -- written ON that host only.
#                 The relocking machine's copy of another host's directory is
#                 a mirror that scripts/tuning-cache-relock.sh replaces at
#                 every gather, so a file refreshed into the mirror would be
#                 lost at the next relock (or, worse, survive one and then
#                 vanish). cache_dir refuses that case.

# Exit status of cache_dir: 0 = the directory is on stdout; 3 = another
# host's migrated cache, nothing to do here (the callers skip it, so a
# `cache-refresh` loop over every host still refreshes the rest); 4 = an error.

# input_path HOST: the absolute path the lock's tuning-cache-HOST input points
# at, or empty when it is a path inside the repo (or there is no such input).
input_path() {
  local p
  p=$(jq -r --arg i "tuning-cache-$1" '.nodes[$i].original.path // empty' "$FLAKE_ROOT/flake.lock")
  case $p in
    /*) echo "$p" ;;
    *) ;;
  esac
}

cache_dir() {
  local p
  p=$(input_path "$1")
  if [ -z "$p" ]; then
    echo "$FLAKE_ROOT/tuning/runtime-cache/hosts/$1"
  elif [ "$1" != "$(hostname)" ]; then
    echo "cache_dir: $1's cache is migrated ($p): refresh it ON $1 (cache-refresh-local), then relock (scripts/tuning-cache-relock.sh)" >&2
    return 3
  elif [ ! -d "$p" ]; then
    echo "cache_dir: flake.lock points tuning-cache-$1 at $p, which does not exist here: run scripts/tuning-cache-migrate.sh" >&2
    return 4
  else
    echo "$p"
  fi
}

# put_cache SRC DEST: move a finished cache file into place. The migrated
# directory is root's (users write only under users/), so the system's files
# go in through sudo there. 0644 either way: mktemp makes 0600 files, and a
# cache file only root can read is invisible to every user's evaluation.
put_cache() {
  if [ -w "$(dirname "$2")" ]; then
    chmod 0644 "$1" && mv "$1" "$2"
  else
    sudo install -m 0644 -o root -g root "$1" "$2" && rm -f "$1"
  fi
}
