# nixos-epoch-record: append {rev, epoch, generation, ...} for the running
# system to the history, plus any system generation in the boot menu that is
# not in it yet. Runs as root from nixos-epoch-record.service; see nixos.nix
# for why this is a unit and not an activation snippet.

hist=$EPOCH_HISTORY
mkdir -p "$(dirname "$hist")"
touch "$hist"
chmod 0644 "$hist"

profiles=/nix/var/nix/profiles

# Highest generation number whose link resolves to $1 ("" if none: a
# `nixos-rebuild test` activates a toplevel that no profile link names).
gen_of() {
  local l n best=""
  for l in "$profiles"/system-*-link; do
    [ -e "$l" ] || continue
    [ "$(readlink -f "$l")" = "$1" ] || continue
    n=${l##*/system-}
    n=${n%-link}
    best=$n
  done
  printf '%s' "$best"
}

# Already recorded with this toplevel? (The dedupe key is the toplevel, not
# the rev: two toplevels from one rev differ in something that matters.)
known() { grep -qF "\"toplevel\":\"$1\"" "$hist"; }

# $1 toplevel, $2 source ("current" | "profile")
emit() {
  local top=$1 src=$2 gen
  gen=$(gen_of "$top")
  if [ -r "$top/epoch.json" ]; then
    jq -c --arg top "$top" --arg gen "$gen" --arg src "$src" --arg t "$(date -Is)" \
      '{time: $t, rev, epoch, host, generation: ($gen | tonumber? // null), toplevel: $top, source: $src}' \
      "$top/epoch.json"
  else
    # A generation from before my.epoch: nothing to hash it with at runtime
    # (computing an epoch needs the flake), so it is recorded as unknown.
    # hm-switch never matches a null epoch.
    jq -nc --arg top "$top" --arg gen "$gen" --arg src "$src" --arg t "$(date -Is)" \
      '{time: $t, rev: null, epoch: null, host: null, generation: ($gen | tonumber? // null), toplevel: $top, source: $src}'
  fi
}

exec 9>>"$hist"
flock 9

cur=$(readlink -f /run/current-system)
# The running system is always appended when it differs from the LAST line,
# so the file is also a log of what ran when (a rollback shows up as an
# older toplevel reappearing), not only a lookup table.
last_top=$(tail -n1 "$hist" | jq -r '.toplevel // empty' 2>/dev/null || true)
if [ "$last_top" != "$cur" ]; then
  emit "$cur" current >&9
fi

# Backfill the boot menu: generations built with `nixos-rebuild boot`, or
# switched to while this unit was not yet part of the system.
for l in "$profiles"/system-*-link; do
  [ -e "$l" ] || continue
  top=$(readlink -f "$l")
  [ -r "$top/epoch.json" ] || continue
  known "$top" || emit "$top" profile >&9
done
