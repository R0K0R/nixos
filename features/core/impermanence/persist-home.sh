# persist-home USER UID GROUP HOME PERSIST MODE SYSTEM_JSON   (as root, at boot)
#
# MODE whole: the whole home is PERSIST (a user whose home axis is persistent).
# MODE lists: the home is fresh; bind PERSIST/<p> onto HOME/<p> for every entry
# of the user's own list (PERSIST/.persist.json, written by their home
# activation from my.persist) merged with SYSTEM_JSON (features' my.state.user
# and the always-kept home-manager state).
set -euo pipefail
u=$1 uid=$2 group=$3 home=$4 persist=$5 mode=$6 sysjson=$7

install -d -m 0700 -o "$uid" -g "$group" "$persist" "$home"

if [ "$mode" = whole ]; then
  mountpoint -q "$home" || mount --bind "$persist" "$home"
  exit 0
fi

# A path is relative, normalised, and never leaves the home.
ok() {
  case $1 in "" | /* | . | ./* | */. | ../* | */.. | */../* | ..) return 1 ;; esac
  case $1 in *//*) return 1 ;; esac
  return 0
}

# Create HOME/<p>'s parents as the user, refusing any component that already
# exists as a symlink (the home is fresh, so one would have to be planted).
parents() {
  local rel=$1 cur=$home part
  IFS=/ read -ra parts <<<"$(dirname "$rel")"
  for part in "${parts[@]}"; do
    [ "$part" = . ] && continue
    cur=$cur/$part
    [ -L "$cur" ] && { echo "persist-home[$u]: $cur is a symlink, skipping $rel" >&2; return 1; }
    [ -d "$cur" ] || install -d -m 0755 -o "$uid" -g "$group" "$cur"
  done
}

entries() {
  local kind=$1
  {
    jq -r --arg k "$kind" '.[$k][]?' "$sysjson"
    [ -f "$persist/.persist.json" ] && jq -r --arg k "$kind" '.[$k][]? | strings' "$persist/.persist.json"
  } | sort -u
}

entries directories | while IFS= read -r p; do
  ok "$p" || { echo "persist-home[$u]: refusing path '$p'" >&2; continue; }
  parents "$p" || continue
  [ -e "$persist/$p" ] || install -d -m 0700 -o "$uid" -g "$group" "$persist/$p"
  [ -L "$home/$p" ] && { echo "persist-home[$u]: $home/$p is a symlink, skipping" >&2; continue; }
  [ -d "$home/$p" ] || install -d -m 0700 -o "$uid" -g "$group" "$home/$p"
  mountpoint -q "$home/$p" || mount --bind "$persist/$p" "$home/$p"
done

entries files | while IFS= read -r p; do
  ok "$p" || { echo "persist-home[$u]: refusing path '$p'" >&2; continue; }
  parents "$p" || continue
  install -d -m 0700 -o "$uid" -g "$group" "$(dirname "$persist/$p")"
  [ -e "$persist/$p" ] || install -m 0600 -o "$uid" -g "$group" /dev/null "$persist/$p"
  [ -L "$home/$p" ] && { echo "persist-home[$u]: $home/$p is a symlink, skipping" >&2; continue; }
  [ -e "$home/$p" ] || install -m 0600 -o "$uid" -g "$group" /dev/null "$home/$p"
  mountpoint -q "$home/$p" || mount --bind "$persist/$p" "$home/$p"
done
