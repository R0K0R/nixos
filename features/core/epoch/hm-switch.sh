# hm-switch [--update] [--force] [--repo DIR] [--on PEER | --local] [--eval-on PEER]
#           [-b EXT] [-- home-manager switch args...]
#
# `home-manager switch` of a home repo built on this system flake's homeLib
# (default ~/config/home, configuration "$USER@<host>"), with two additions.
#
# 1. THE EPOCH QUESTION, asked first when my.epoch is on: was the system
#    revision this home is locked to deployed HERE, with the epoch the machine
#    is running now? If not, the home would be built against a different
#    system surface (graphics driver, PAM modules, ...) than the one it will
#    run on. ADVISORY BY DESIGN: --force, or `home-manager switch` run
#    directly, skips it; the enforcing half is system-side (session-epoch-check
#    at login). With my.epoch off there is nothing to compare, and hm-switch
#    says so and goes on.
#
# 2. WHERE IT BUILDS, the variations the system's nixos-rebuild-<peer> /
#    -local wrappers have:
#      --on PEER       only PEER builds (max-jobs 0 here)
#      --local         no remote builders
#      --eval-on PEER  evaluate on PEER (copy the repo there, `nix eval` the
#                      activationPackage's .drvPath, copy back the .drv files
#                      this store lacks), then build as above
#    Pinning builders is a trusted-user setting, and people are untrusted on
#    the shared daemon, so HOW depends on the host:
#      class daemon    (features/nix/class-daemons) the user's class has a
#                      socket per variant; picking the variant is picking the
#                      socket (NIX_REMOTE), no trust needed. Evaluation goes
#                      through the same socket, so an import-from-derivation
#                      build is pinned too.
#      sudo            otherwise, for a user with the registry's sudo grant:
#                      evaluation stays the user's, only the BUILD of the
#                      finished .drv runs as root with the wrappers' options
#                      (never evaluating a user repo as root: its lock may
#                      name root-only paths, which would land in the store).
#      neither         the shared daemon ignores the pin; hm-switch says so and
#                      builds with the system's builders.
#    Activation always runs as the user: the activationPackage's ./activate,
#    exactly as home-manager runs it (profile link first when the generation
#    has a gen-version file).
#
# The variations only build and activate; extra home-manager arguments (after
# --) are for the plain path. -b EXT works for both.

usage() {
  cat <<'EOF'
usage: hm-switch [--update] [--force] [--repo DIR] [--on PEER | --local]
                 [--eval-on PEER] [-b EXT] [-- home-manager switch args...]

  --update        relock the repo's `system` input to the newest revision
                  deployed on this machine with the current epoch, then switch
                  (needs my.epoch)
  --force         switch even if the locked system revision's epoch is unknown
                  or different (you get a home built for another system surface)
  --repo DIR      the home repo (default: $HM_REPO or ~/config/home)
  --on PEER       build on PEER only
  --local         build without remote builders
  --eval-on PEER  evaluate on PEER, copy the derivations back, build as chosen
  -b EXT          back up files in the way with this extension
EOF
  if [ -n "$HM_PEERS" ]; then printf '\npeers: %s\n' "$HM_PEERS"; fi
}

update=0 force=0 repo="${HM_REPO:-$HOME/config/home}"
build=system peer='' evalon='' backup=''
while [ $# -gt 0 ]; do
  case $1 in
    --update) update=1 ;;
    --force) force=1 ;;
    --repo) [ $# -ge 2 ] || { usage >&2; exit 2; }; repo=$2; shift ;;
    --on) [ $# -ge 2 ] || { usage >&2; exit 2; }; [ "$build" = system ] || { echo "hm-switch: --on and --local exclude each other" >&2; exit 2; }; build=peer peer=$2; shift ;;
    --local) [ "$build" = system ] || { echo "hm-switch: --on and --local exclude each other" >&2; exit 2; }; build=local ;;
    --eval-on) [ $# -ge 2 ] || { usage >&2; exit 2; }; evalon=$2; shift ;;
    -b) [ $# -ge 2 ] || { usage >&2; exit 2; }; backup=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'hm-switch: %s\n' "$*" >&2; exit 1; }
note() { printf 'hm-switch: %s\n' "$*" >&2; }
is_peer() { case " $HM_PEERS " in *" $1 "*) return 0 ;; esac; return 1; }

if [ "$build" = peer ] && ! is_peer "$peer"; then die "--on $peer: not a peer of this host (peers: ${HM_PEERS:-none})"; fi
if [ -n "$evalon" ] && ! is_peer "$evalon"; then die "--eval-on $evalon: not a peer of this host (peers: ${HM_PEERS:-none})"; fi
if { [ "$build" != system ] || [ -n "$evalon" ]; } && [ $# -gt 0 ]; then
  die "extra home-manager arguments ($*) only go with the plain path, not --on/--local/--eval-on"
fi

host=$(system_host)
[ -n "$host" ] || host=$(cat /proc/sys/kernel/hostname)
name="$USER@$host"
lock=$repo/flake.lock
[ -r "$lock" ] || die "no flake.lock in $repo"

# --- 1. the epoch check (advisory) --------------------------------------
cur=$(system_epoch)
rev=
if [ -z "$cur" ]; then
  [ "$update" = 1 ] && die "--update relocks to a revision recorded in the epoch history, and my.epoch is off on $host"
  note "my.epoch is off on $host: the lock is not checked against the running system"
else
  node=$(lock_system_node "$lock")
  [ -n "$node" ] || die "$lock has no plain 'system' input (missing, or a follows)"

  if [ "$update" = 1 ]; then
    target=$(newest_rev_of_epoch "$cur")
    if [ -z "$target" ]; then
      r=$(system_rev)
      case $r in
        "" | *-dirty)
          die "no clean revision with epoch $cur is recorded on this machine.
The running system was deployed from ${r:-an unknown revision} (an uncommitted tree?).
Ask the admin to commit, push and redeploy -- or use --force at your own risk." ;;
      esac
      target=$r
    fi
    # Rebuild the input's URL around the new rev from the lock's own `original`,
    # so a github input stays github and a git+file checkout stays local.
    url=$(jq -r --arg n "$node" --arg rev "$target" '
      .nodes[$n].original as $o
      | if $o.type == "github" then "github:\($o.owner)/\($o.repo)/\($rev)"
        elif $o.type == "gitlab" then "gitlab:\($o.owner)/\($o.repo)/\($rev)"
        elif $o.type == "git" then "git+\($o.url)?rev=\($rev)"
        else empty end' "$lock")
    [ -n "$url" ] || die "cannot pin the 'system' input to a revision: its type is $(jq -r --arg n "$node" '.nodes[$n].original.type' "$lock"). Point system.url at github: or git+file: instead."
    printf 'hm-switch: relocking system -> %s (epoch %s)\n' "$target" "$cur"
    (cd "$repo" && nix flake lock --override-input system "$url") || die "relock failed"
  fi

  rev=$(lock_system_rev "$lock")
  [ -n "$rev" ] || die "the locked 'system' input has no rev (a path: input?); cannot look up its epoch"
  locked_epoch=$(history_epoch_of_rev "$rev")

  if [ "$locked_epoch" != "$cur" ] && [ "$force" != 1 ]; then
    if [ -z "$locked_epoch" ]; then
      why="system revision $rev (locked in $lock) was never deployed on $host,
so its epoch is unknown here."
    else
      why="system revision $rev (locked in $lock) has epoch $locked_epoch,
but $host is running epoch $cur."
    fi
    newest=$(newest_rev_of_epoch "$cur")
    cat >&2 <<EOF
hm-switch: refusing to switch.
$why
A home built against it may load system code (graphics driver, PAM modules,
locale archive) that does not match the running system.

Fix: hm-switch --update${newest:+   (relocks system to $newest)}
     or hm-switch --force to switch anyway.
EOF
    exit 1
  fi
fi

# --- 2. where it builds ---------------------------------------------------
# Sets: route (class | sudo | system), buildopts, and NIX_REMOTE for a class
# daemon. A class socket counts only if it is WRITABLE: right after the switch
# that made the user a member of nix-class-<class>, a running session does not
# have the group yet.
usable() { [ -S "$1" ] && [ -w "$1" ]; }
route=system
buildopts=()
cdir=$(hm_class_dir "$USER") || cdir=
if [ -n "$cdir" ] && ! usable "$cdir/default"; then
  note "your class daemon ($cdir/default) is not usable from this session (log in again after the switch that added you to its group); falling back"
  cdir=
fi
use_class() { route=class; export NIX_REMOTE="unix://$cdir/$1"; }

case $build in
  system)
    [ -n "$cdir" ] && use_class default
    ;;
  peer)
    if [ -n "$cdir" ] && usable "$cdir/$peer"; then
      use_class "$peer"
    elif [ -n "$cdir" ]; then
      die "$peer is not a builder of your class on $host (sockets: $(cd "$cdir" && echo *))"
    elif hm_sudo_user "$USER" && hm_pin "$peer"; then
      route=sudo
      # shellcheck disable=SC2154 # pin_* are set by hm_pin (generated)
      buildopts=(--option max-jobs 0 --option builders "$pin_builders" --option substituters "$pin_substituters")
    else
      note "no class daemon and no sudo grant: the shared daemon ignores a pinned builder from an untrusted user -- building with the system's builders"
    fi
    ;;
  local)
    if [ -n "$cdir" ] && usable "$cdir/local"; then
      use_class local
    elif [ -n "$cdir" ]; then
      use_class default
      buildopts=(--option builders "")
      [ "$HM_HOST_MAX_JOBS" = 0 ] && note "your class has no local variant and $host builds nothing locally (max-jobs = 0): only what substitutes will succeed"
    elif hm_sudo_user "$USER" && [ -n "$HM_LOCAL_JOBS" ]; then
      route=sudo
      buildopts=(--option builders "" --option max-jobs "$HM_LOCAL_JOBS" --option cores "$HM_LOCAL_CORES" --option substituters "$HM_LOCAL_SUBST")
    else
      # An empty builders list is the one builder setting an untrusted client may pass.
      buildopts=(--option builders "")
      note "untrusted on the shared daemon: remote builders off, but max-jobs stays the host's ($HM_HOST_MAX_JOBS)"
    fi
    ;;
esac

attr="homeConfigurations.\"$name\".activationPackage"

# Evaluate on a peer: the same steps and the same reasons as the system's
# remoteEval (features/nix/remote-builder/wrappers.nix), as the user. Prints
# the .drv path; returns 2 when the peer cannot be used (caller evaluates here).
remote_eval() {
  local p=$1 ruser="${HM_SWITCH_REMOTE_USER:-$USER}" store src drv list missing tmp
  store="ssh-ng://$ruser@$p"
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$ruser@$p" true 2>/dev/null || { note "$p is unreachable as $ruser"; return 2; }
  note "copying $repo to $p"
  src=$(nix flake archive --json --to "$store" "$repo" | jq -r .path) && [ -n "$src" ] \
    || { note "nix flake archive to $p failed"; return 2; }
  note "evaluating on $p"
  eval_cmd="nix eval --raw '$src#$attr.drvPath'"
  if [ -t 0 ] && [ -t 2 ]; then
    tmp=$(ssh -o BatchMode=yes "$ruser@$p" mktemp) || { note "mktemp on $p failed"; return 2; }
    ssh -qtt -o BatchMode=yes "$ruser@$p" "$eval_cmd > $tmp" >&2 \
      || { ssh -o BatchMode=yes "$ruser@$p" rm -f "$tmp"; note "evaluation failed on $p (see above)"; return 1; }
    drv=$(ssh -o BatchMode=yes "$ruser@$p" "cat $tmp; rm -f $tmp")
  else
    drv=$(ssh -o BatchMode=yes "$ruser@$p" "$eval_cmd") || { note "evaluation failed on $p (see above)"; return 1; }
  fi
  case $drv in /nix/store/*.drv) ;; *) note "no .drv from $p: $drv"; return 1 ;; esac
  note "copying the derivations back"
  # Only what is missing, listed on the peer in one call (see wrappers.nix for
  # the measurements). As the user: .drv files are content-addressed, which a
  # daemon accepts from untrusted clients without signatures.
  list=$(ssh -o BatchMode=yes "$ruser@$p" nix-store -qR "'$drv'") || { note "listing the derivations on $p failed"; return 2; }
  missing=$(printf '%s\n' "$list" | while read -r d; do [ -e "$d" ] || printf '%s\n' "$d"; done)
  if [ -n "$missing" ]; then
    printf '%s\n' "$missing" | nix copy --no-recursive --from "$store" --stdin \
      || { note "copying the derivations back from $p failed"; return 2; }
  fi
  printf '%s\n' "$drv"
}

switch_plain() {
  printf 'hm-switch: %s, system %s, epoch %s, %s\n' "$name" "${rev:-unchecked}" "${cur:-off}" \
    "$([ "$route" = class ] && echo "via $NIX_REMOTE" || echo "shared daemon")"
  local hmargs=()
  if [ -n "$backup" ]; then hmargs=(-b "$backup"); fi
  home-manager switch "${hmargs[@]}" --flake "$repo#$name" "$@"
}

switch_variant() {
  local drv out profiles s
  printf 'hm-switch: %s, system %s, epoch %s, build %s%s via %s%s\n' "$name" "${rev:-unchecked}" "${cur:-off}" \
    "$build" "${peer:+ ($peer)}" "$route" "${evalon:+, evaluated on $evalon}"
  if [ -n "$evalon" ]; then
    drv=$(remote_eval "$evalon")
    s=$?
    [ "$s" = 1 ] && return 1
    [ "$s" = 0 ] || { note "falling back to evaluating here"; drv=; }
  fi
  if [ -z "${drv:-}" ]; then
    drv=$(nix eval --raw "$repo#$attr.drvPath") || { note "evaluation failed"; return 1; }
  fi
  if [ "$route" = sudo ]; then
    note "building as root (sudo): pinning builders is a trusted-user setting"
    out=$(sudo -- "$HM_NIX" build --no-link --print-out-paths "$drv^out" "${buildopts[@]}") || { note "build failed"; return 1; }
  else
    out=$(nix build --no-link --print-out-paths "$drv^out" "${buildopts[@]}") || { note "build failed"; return 1; }
  fi
  out=$(printf '%s\n' "$out" | tail -n1)
  [ -x "$out/activate" ] || { note "no activate script in $out"; return 1; }
  # As home-manager's own switch: link the profile, then activate. A
  # generation without gen-version is a legacy one whose activation links the
  # profile itself.
  if [ -e "$out/gen-version" ]; then
    profiles=$(hm_profile_dir) || profiles=${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles
    mkdir -p "$profiles"
    nix-env --profile "$profiles/home-manager" --set "$out" || { note "setting the profile failed"; return 1; }
  fi
  if [ -n "$backup" ]; then export HOME_MANAGER_BACKUP_EXT="$backup"; fi
  "$out/activate" --driver-version 1
}

state=$(hm_switch_state)
mkdir -p "$state"
log=$state/last.log
if [ "$build" = system ] && [ -z "$evalon" ]; then
  switch_plain "$@" 2>&1 | tee "$log"
else
  switch_variant 2>&1 | tee "$log"
fi
status=${PIPESTATUS[0]}
if [ "$status" != 0 ]; then
  cp -f "$log" "$state/last-failed.log"
  printf 'hm-switch: switch failed (exit %s); log in %s\n' "$status" "$state/last-failed.log" >&2
  exit "$status"
fi
rm -f "$state/last-failed.log"

# The new generation should carry its epoch; say so if the repo does not
# include homeLib.<host>.epochModule, since rollback checks depend on it.
if [ -n "$cur" ]; then
  g=$(current_home_gen "$USER" "$HOME") || true
  if [ -n "$g" ] && [ -z "$(gen_epoch "$g")" ]; then
    echo "hm-switch: note: this generation records no epoch; add system.homeLib.$host.epochModule to your modules" >&2
  fi
fi
