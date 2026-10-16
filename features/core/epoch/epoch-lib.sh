# Sourced by hm-switch, hm-rollback, session-epoch-check, fallback-banner,
# fallback-brief and the PAM banner. Not executable on its own.
#
# Everything here treats what it reads as DATA: the history file, a home
# generation's `epoch` file and the user's flake.lock are parsed with jq or
# filtered to a fixed alphabet, never sourced or eval'ed -- the PAM banner runs
# this as root over files the user controls.
#
# Expects EPOCH_HISTORY to be set by the wrapper (the system's history file).

: "${EPOCH_HISTORY:?EPOCH_HISTORY unset}"

# The running system's record, written into the toplevel by the epoch feature.
# /run/current-system, not /run/booted-system: after `nixos-rebuild switch`
# the switched-to generation is what user processes now see.
# EPOCH_SYS_JSON overrides it for testing, but never for root: the PAM
# banner runs as root with an environment the user may influence.
epoch_sys_json=/run/current-system/epoch.json
if [ -n "${EPOCH_SYS_JSON:-}" ] && [ "$(id -u)" != 0 ]; then epoch_sys_json=$EPOCH_SYS_JSON; fi

system_epoch() { jq -r '.epoch // empty' "$epoch_sys_json" 2>/dev/null; }
system_rev() { jq -r '.rev // empty' "$epoch_sys_json" 2>/dev/null; }
system_host() { jq -r '.host // empty' "$epoch_sys_json" 2>/dev/null; }

# One JSON object per line; a corrupt line is skipped rather than poisoning
# every lookup (fromjson? swallows it).
history_lines() {
  [ -r "$EPOCH_HISTORY" ] || return 0
  jq -cR 'fromjson? // empty' "$EPOCH_HISTORY"
}

# epoch recorded for a system rev, newest record wins; empty if never deployed.
history_epoch_of_rev() {
  history_lines | jq -rs --arg r "$1" '[.[] | select(.rev == $r)] | last | .epoch // empty'
}

# Newest CLEAN rev deployed (or sitting in the boot menu) with this epoch. A
# "-dirty" rev was built from an uncommitted tree: nobody can lock to it.
newest_rev_of_epoch() {
  history_lines | jq -rs --arg e "$1" '
    [.[] | select(.epoch == $e and (.rev // "") != "" and ((.rev | endswith("-dirty")) | not))]
    | last | .rev // empty'
}

# Last few distinct clean revs of an epoch, newest first (for the brief).
revs_of_epoch() {
  history_lines | jq -rs --arg e "$1" '
    [.[] | select(.epoch == $e and (.rev // "") != "") | .rev] | reverse
    | reduce .[] as $r ([]; if index([$r]) then . else . + [$r] end) | .[:5] | .[]'
}

# A generation's recorded epoch, filtered to the alphabet epochs use. Empty
# means "unrecorded": built without homeLib.<host>.epochModule, or before it.
gen_epoch() {
  [ -r "$1/epoch" ] || return 0
  head -c 64 "$1/epoch" | tr -cd 'a-z0-9'
}

# The user's home-manager profile directory (standalone first, then the
# legacy per-user location the integrated module still uses on some setups).
hm_profile_dir() {
  local u="${1:-$USER}" h="${2:-$HOME}" d
  for d in "${XDG_STATE_HOME:-$h/.local/state}/nix/profiles" "/nix/var/nix/profiles/per-user/$u"; do
    if [ -e "$d/home-manager" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  return 1
}

# "<n> <link>" per home-manager generation, oldest first.
hm_generations() {
  local d l n
  d=$(hm_profile_dir "$@") || return 0
  for l in "$d"/home-manager-*-link; do
    [ -e "$l" ] || continue
    n=${l##*/home-manager-}
    n=${n%-link}
    case $n in *[!0-9]*) continue ;; esac
    printf '%s %s\n' "$n" "$l"
  done | sort -n
}

# The ACTIVE home generation (what the last activation linked), not the
# newest one in the profile: a failed or rolled-back switch leaves those apart.
current_home_gen() {
  local h="${2:-$HOME}" g
  g="${XDG_STATE_HOME:-$h/.local/state}/home-manager/gcroots/current-home"
  if [ -e "$g" ]; then
    readlink -f "$g"
    return 0
  fi
  local d
  d=$(hm_profile_dir "$@") || return 1
  readlink -f "$d/home-manager"
}

# Number of the generation whose link resolves to a given store path.
gen_number_of() {
  local target="$1" n l
  shift
  hm_generations "$@" | while read -r n l; do
    [ "$(readlink -f "$l")" = "$target" ] && echo "$n"
  done | tail -n1
}

# "<n> <link>" of the newest generation recorded for an epoch, if any.
newest_gen_of_epoch() {
  local e="$1" n l
  shift
  # An empty epoch would "match" every unrecorded generation.
  [ -n "$e" ] || return 0
  hm_generations "$@" | sort -rn | while read -r n l; do
    if [ "$(gen_epoch "$l")" = "$e" ]; then
      printf '%s %s\n' "$n" "$l"
      break
    fi
  done
}

# Where hm-switch keeps its logs; fallback-brief reads the failure log.
hm_switch_state() { printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/hm-switch"; }

# The node name of the `system` input in a flake.lock; empty if absent or a
# `follows` (an array), which hm-switch cannot reason about.
lock_system_node() {
  jq -r '.nodes.root.inputs.system // empty | if type == "string" then . else empty end' "$1" 2>/dev/null
}
lock_system_rev() {
  local node
  node=$(lock_system_node "$1")
  [ -n "$node" ] || return 0
  jq -r --arg n "$node" '.nodes[$n].locked.rev // empty' "$1"
}
