# tuning-refresh [--repo DIR] [--print]       your own evidence, for this host
# tuning-refresh --user NAME [--repo DIR]     root: NAME's, run AS NAME
# tuning-refresh --all                        root: every user of this host
#
# --print writes the file to stdout instead of into the cache directory, and
# does not need the directory to exist: a dry run, before the admin has set
# anything up (or with TUNING_CACHE_DIR pointed at a scratch directory, the
# same run against a copy).
#
# Writes $TUNING_CACHE_DIR/<host>/users/<user>.nix (default
# /var/lib/tuning-cache): the package names this user's home actually runs,
# which the tuning classifier then counts as host-runtime on this host --
# for every package set here, after the admin relocks the cache
# (docs/multiuser-design.md, "Every user feeds the classifier").
#
# The evidence is BOTH
#   closure     every package the current home generation references (after
#               a switch -- the same method as the system's Tier 1), and
#   evaluation  home.packages of the home repo's configuration for this host,
#               walked through buildInputs/propagatedBuildInputs (before a
#               switch, your own modules included -- Tier 2's method).
#
# Root never evaluates a user's repo as root: a flake.lock can name paths only
# root may read, and evaluating it would copy them into the world-readable
# store. Root's runs re-execute this AS the user -- runuser, or for an overlay
# guest (registry nix = "overlay") their own user manager, which runs in
# their namespace with their store.

die() { echo "tuning-refresh: $*" >&2; exit 1; }

host=$(hostname)
cache=${TUNING_CACHE_DIR:-/var/lib/tuning-cache}
repo=""
target="" all=0 print=0
while [ $# -gt 0 ]; do
  case $1 in
    --user) target=$2; shift ;;
    --all) all=1 ;;
    --repo) repo=$2; shift ;;
    --print) print=1 ;;
    -h | --help)
      echo "usage: tuning-refresh [--repo DIR] [--print] | --user NAME [--repo DIR] | --all"
      exit 0
      ;;
    *) die "unknown argument $1" ;;
  esac
  shift
done

if [ "$all" = 1 ] || [ -n "$target" ]; then
  [ "$(id -u)" = 0 ] || die "--user/--all are root's (anyone can refresh their own: plain tuning-refresh)"
  users=$target
  if [ "$all" = 1 ]; then
    users=$(nix eval --raw --impure --expr "
      let r = (builtins.getFlake \"$SYSTEM_FLAKE\").registry;
      in builtins.concatStringsSep \" \" r.hosts.hosts.\"$host\".users") || die "cannot read the registry from $SYSTEM_FLAKE"
  fi
  rc=0
  for u in $users; do
    access=$(nix eval --raw --impure --expr "
      ((builtins.getFlake \"$SYSTEM_FLAKE\").registry.effective.\"$host\".\"$u\").nix" 2>/dev/null || echo unknown)
    echo "== $u ($access)" >&2
    r=0
    if [ "$access" = overlay ]; then
      systemd-run --user --machine="$u@" --wait --pipe --quiet -- "$0" ${repo:+--repo "$repo"} || r=$?
    else
      # A clean environment, not root's: runuser keeps most of the caller's
      # variables, and root's NIX_*/XDG_* would point the user's nix at
      # root's config and caches.
      uhome=$(getent passwd "$u" | cut -d: -f6)
      runuser -u "$u" -- env -i PATH="$PATH" HOME="$uhome" USER="$u" LOGNAME="$u" \
        ${TUNING_CACHE_DIR:+TUNING_CACHE_DIR="$TUNING_CACHE_DIR"} "$0" ${repo:+--repo "$repo"} || r=$?
    fi
    case $r in
      0) ;;
      2) echo "   skipped: $u has no standalone home here" >&2 ;;
      *) rc=1 ;;
    esac
  done
  exit $rc
fi

user=$(id -un)
repo=${repo:-${HM_REPO:-$HOME/config/home}}
dir=$cache/$host/users
if [ "$print" = 0 ]; then
  [ -d "$dir" ] && [ -w "$dir" ] || die "$dir does not exist or is not writable: the admin has not set up the tuning cache on $host yet (my.tuning.userCache.enable, scripts/tuning-cache-migrate.sh); --print shows what would be written"
fi
# Exit 2, not 1: root's --all skips such a user instead of failing (an
# integrated home, homeActivation = "system", is already the system's own
# evidence; an account without a home repo has nothing of its own).
if ! [ -e "$repo/flake.nix" ]; then
  echo "tuning-refresh: no home repo at $repo (--repo DIR, or HM_REPO)" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Closure of the current home generation, by pname from each path's deriver
#    (refresh-tier1.sh's method: unambiguous, unlike parsing store path names).
gen=$HOME/.local/state/nix/profiles/home-manager
if [ -e "$gen" ]; then
  nix-store -q --requisites "$gen" \
    | xargs -r nix-store -q --deriver 2>/dev/null \
    | grep '\.drv$' \
    | while read -r d; do [ -e "$d" ] && echo "$d"; done \
    | xargs -r -n 200 nix derivation show 2>/dev/null \
    | jq -s -r '[.[] | .derivations | to_entries[] | (.value.env.pname // .value.structuredAttrs.pname // empty)] | unique | .[]' \
      >"$tmp/closure" || true
else
  echo "tuning-refresh: no home generation yet ($gen) -- evaluation only" >&2
  : >"$tmp/closure"
fi

# 2. Evaluation of the home repo for this host, and the nixpkgs it is stamped with.
nix eval --json --impure --expr "
  let
    f = builtins.getFlake \"$repo\";
    h = f.homeConfigurations.\"$user@$host\";
    lib = f.inputs.system.inputs.nixpkgs.lib;
    keyOf = p: p.pname or p.name or \"unknown\";
    isPkg = p: lib.isDerivation p && (p ? pname || p ? name);
    closure = builtins.genericClosure {
      startSet = map (p: { key = keyOf p; inherit p; }) (builtins.filter isPkg h.config.home.packages);
      operator = { p, ... }: map (q: { key = keyOf q; p = q; }) (
        builtins.filter isPkg ((p.buildInputs or [ ]) ++ (p.propagatedBuildInputs or [ ])));
    };
  in {
    names = map (i: i.key) closure;
    narHash = f.inputs.system.inputs.nixpkgs.narHash;
    rev = f.inputs.system.inputs.nixpkgs.rev;
  }" >"$tmp/eval.json" || die "evaluating $repo#homeConfigurations.\"$user@$host\" failed"
jq -r '.names[]' "$tmp/eval.json" >"$tmp/evalnames"

sort -u "$tmp/closure" "$tmp/evalnames" | grep -v '^$' >"$tmp/names"

export TR_NAMES="$tmp/names" TR_HOST="$host" TR_USER="$user"
TR_NARHASH=$(jq -r .narHash "$tmp/eval.json") TR_REV=$(jq -r .rev "$tmp/eval.json")
TR_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export TR_NARHASH TR_REV TR_AT
nix eval --impure --expr '
  let
    e = n: builtins.getEnv "TR_${n}";
    lines = builtins.filter (s: builtins.isString s && s != "") (builtins.split "\n" (builtins.readFile (e "NAMES")));
  in {
    host = e "HOST";
    user = e "USER";
    capturedAt = e "AT";
    nixpkgsNarHash = e "NARHASH";
    nixpkgsRev = e "REV";
    runtimeNames = lines;
  }' >"$tmp/out.nix"
summary="$(wc -l <"$tmp/names") names: $(wc -l <"$tmp/closure") from the closure, $(wc -l <"$tmp/evalnames") from the evaluation"
if [ "$print" = 1 ]; then
  cat "$tmp/out.nix"
  echo "tuning-refresh: --print, nothing written ($summary; would be $dir/$user.nix)" >&2
  exit 0
fi
# 0644 whatever the umask: the relock's gather reads every user's file over
# ssh as the admin, not as root, and silently copies nothing it cannot read.
# Written next to the target, then renamed, so a concurrent relock never
# locks half a file (lookup.nix reads only *.nix, not the .tmp).
install -m 0644 "$tmp/out.nix" "$dir/.$user.nix.tmp"
mv -f "$dir/.$user.nix.tmp" "$dir/$user.nix"
echo "wrote $dir/$user.nix ($summary) -- counts once the admin relocks the cache"
