# Sourced by the refresh scripts. Where a host's classifier cache lives on
# THIS machine: /var/lib/tuning-cache/<host> once the admin has migrated it
# (scripts/tuning-cache-migrate.sh), the in-repo copy before that.
cache_dir() {
  if [ -d "/var/lib/tuning-cache/$1" ]; then
    echo "/var/lib/tuning-cache/$1"
  else
    echo "$FLAKE_ROOT/tuning/runtime-cache/hosts/$1"
  fi
}

# put_cache SRC DEST: move a finished cache file into place. The migrated
# directory is root's (users write only under users/), so the system's files
# go in through sudo there.
put_cache() {
  if [ -w "$(dirname "$2")" ]; then
    mv "$1" "$2"
  else
    sudo install -m 0644 -o root -g root "$1" "$2" && rm -f "$1"
  fi
}
