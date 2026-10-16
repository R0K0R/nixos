# hm-switch [--update] [--force] [--repo DIR] [-- home-manager args...]
#
# `home-manager switch` for a home repo built on this system flake's homeLib,
# with one question asked first: was the system revision this home is locked
# to deployed HERE, with the epoch the machine is running now? If not, the
# home would be built against a different system surface (graphics driver, PAM
# modules, ...) than the one it will run on.
#
# ADVISORY BY DESIGN. Nothing stops `home-manager switch` run directly, or
# --force; this exists so the safe path is also the easy one. The enforcing
# half is system-side (session-epoch-check at login).

usage() {
  cat <<'EOF'
usage: hm-switch [--update] [--force] [--repo DIR] [-- home-manager switch args...]

  --update   relock the repo's `system` input to the newest revision deployed
             on this machine with the current epoch, then switch
  --force    switch even if the locked system revision's epoch is unknown or
             different (you get a home built for another system surface)
  --repo     the home repo (default: $HM_REPO or ~/config/home)
EOF
}

update=0 force=0 repo="${HM_REPO:-$HOME/config/home}"
while [ $# -gt 0 ]; do
  case $1 in
    --update) update=1 ;;
    --force) force=1 ;;
    --repo) repo=$2; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

die() { printf 'hm-switch: %s\n' "$*" >&2; exit 1; }

lock=$repo/flake.lock
[ -r "$lock" ] || die "no flake.lock in $repo"
cur=$(system_epoch)
[ -n "$cur" ] || die "the running system records no epoch (/run/current-system/epoch.json); my.epoch is off on this host"
host=$(system_host)
[ -n "$host" ] || host=$(cat /proc/sys/kernel/hostname)

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

state=$(hm_switch_state)
mkdir -p "$state"
log=$state/last.log
printf 'hm-switch: %s@%s, system %s, epoch %s\n' "$USER" "$host" "$rev" "$cur"
home-manager switch --flake "$repo#$USER@$host" "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" != 0 ]; then
  cp -f "$log" "$state/last-failed.log"
  printf 'hm-switch: home-manager failed (exit %s); log in %s\n' "$status" "$state/last-failed.log" >&2
  exit "$status"
fi
rm -f "$state/last-failed.log"

# The new generation should carry its epoch; say so if the repo does not
# include homeLib.<host>.epochModule, since rollback checks depend on it.
g=$(current_home_gen) || true
if [ -n "$g" ] && [ -z "$(gen_epoch "$g")" ]; then
  echo "hm-switch: note: this generation records no epoch; add system.homeLib.$host.epochModule to your modules" >&2
fi
