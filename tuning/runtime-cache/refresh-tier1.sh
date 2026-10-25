#!/usr/bin/env bash
# Tier 1 of the host-runtime classifier: capture the REAL, live system
# closure and write it to a git-tracked cache file. Run manually, ON the
# target host, after a nixos-rebuild switch/boot:
#   ./refresh-tier1.sh [hostname]
# No argument = this machine's own hostname. Ground truth, not a heuristic --
# see runtime-cache/lookup.nix for how this is combined with Tier 2/3.
#
# Or from ANOTHER machine, over ssh: TIER1_SSH=<ssh target> ./refresh-tier1.sh <hostname>
# reads the closure of the target's /run/current-system there (the only part that
# must run on it), and writes the cache file into THIS checkout, stamped with THIS
# checkout's nixpkgs -- the stamp lookup.nix validates against, so the file is
# valid exactly where it is committed. (cache-refresh-<host> wraps this.)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
. ./cache-dir.sh

HOST="${1:-$(hostname)}"
if [ ! -d "$FLAKE_ROOT/hosts/$HOST" ]; then
  echo "no hosts/$HOST -- pass an explicit hostname matching a hosts/ directory" >&2
  exit 1
fi
# Where it goes, decided first: a migrated cache of another host is not
# written here (cache-dir.sh), so do not spend the closure walk on it.
rc=0
DIR=$(cache_dir "$HOST") || rc=$?
case $rc in
  0) ;;
  3) echo "tier1 for $HOST SKIPPED here" >&2; exit 0 ;;
  *) exit 1 ;;
esac

# Read pname directly from each requisite's own deriver rather than parsing
# it out of the store path string. An earlier version used
# builtins.parseDrvName plus a regex stripping a known splice-disambiguation
# suffix ("-x86_64-unknown-linux-gnu") -- abandoned: a package genuinely
# named e.g. "sox-unstable" is indistinguishable, from the string alone, from
# "sox" plus that suffix appended by nixpkgs' own splicing machinery. Reading
# pname from the derivation's own env (or .structuredAttrs.pname, for
# __structuredAttrs=true derivations, which don't put it in plain env) is
# unambiguous. Slower -- ~3s vs ~1s for ~3350 paths -- but this runs
# manually and infrequently, not on every rebuild, so accuracy wins.
#
# Two failure modes, both real, both handled explicitly rather than trusted
# to just work:
#  - `nix-store -q --deriver` prints the literal string "unknown-deriver" for
#    paths with no known deriver (generated content, etc) -- filtered by
#    only keeping lines ending in .drv.
#  - a .drv can still be reported by --deriver after being garbage collected
#    (Nix doesn't keep .drv files forever once their outputs are built) --
#    `nix derivation show` hard-fails its ENTIRE invocation if even one path
#    in a batch doesn't exist, silently producing zero output for every
#    other (valid) path batched alongside it. Filtered via a plain
#    existence check before batching, not caught after the fact.
# THE TUNED CLOSURE, not the whole one. A system can carry sessions that
# only untuned accounts run (registry/types.nix `tuned`; GNOME for guest and
# handoff on galaxybook4-pro360). Their packages are in the toplevel's
# closure, and counting them would tune them at the next rebuild -- users
# other than r0k0r and benjamin do not use tuning. The toplevel lists them
# in `untuned-roots` (my.tuning.untunedRoots); this walks the references
# from the toplevel without entering those paths, so what the system ALSO
# reaches some other way stays, and what it reaches only through them does
# not. No file (an older generation, a host without such sessions): the
# plain closure, exactly as before. Plain nix-store and coreutils, one
# --references call per level, so it runs the same on a TIER1_SSH target.
TUNED_REQUISITES='
  top=$(readlink -f "$1")
  w=$(mktemp -d); trap "rm -rf $w" EXIT
  if [ -r "$top/untuned-roots" ]; then grep -v "^$" "$top/untuned-roots" | sort -u > "$w/cut"; else : > "$w/cut"; fi
  echo "$top" > "$w/front"; cp "$w/front" "$w/seen"
  while [ -s "$w/front" ]; do
    xargs nix-store -q --references < "$w/front" | sort -u | comm -23 - "$w/seen" | comm -23 - "$w/cut" > "$w/next"
    sort -u -m "$w/seen" "$w/next" -o "$w/seen"
    mv "$w/next" "$w/front"
  done
  echo "untuned-roots: $(grep -c . "$w/cut") cut, $(grep -c . "$w/seen") paths kept" >&2
  cat "$w/seen"'
echo "resolving pnames via each store path's own deriver (accurate, not a string-pattern guess)..."
# The same pipeline locally or on the TIER1_SSH target; quoted once, so the remote
# shell sees it exactly as the local one would.
PNAME_PIPELINE='bash -c "$TUNED_REQUISITES" _ /run/current-system \
  | xargs nix-store -q --deriver 2>/dev/null \
  | grep "\.drv$" \
  | while read -r drv; do if [ -e "$drv" ]; then echo "$drv"; fi; done \
  | xargs -n 200 nix derivation show 2>/dev/null \
  | jq -s -r "[.[] | .derivations | to_entries[] | (.value.env.pname // .value.structuredAttrs.pname // empty)] | unique | .[]"'
if [ -n "${TIER1_SSH:-}" ]; then
  REMOTE_HOST="$(ssh -o BatchMode=yes "$TIER1_SSH" hostname)"
  if [ "$REMOTE_HOST" != "$HOST" ]; then
    echo "TIER1_SSH=$TIER1_SSH is $REMOTE_HOST, not $HOST -- refusing to file one host's closure under another's name" >&2
    exit 1
  fi
  REMOTE_VERSION="$(ssh -o BatchMode=yes "$TIER1_SSH" cat /run/current-system/nixos-version)"
  # The deriver list comes from the target; the .drv files need not. A host GCs its
  # .drvs (victus-15 had 896 of 2032 gone, 2026-10-07), and the plain pipeline then
  # drops those packages silently -- 806 names instead of ~1900. Evaluating the
  # host's toplevel HERE instantiates the same .drvs into this store (same config,
  # same paths), so: show what exists locally, after instantiating if anything is
  # missing; ask the target for whatever still is; report the rest.
  # The walk's script on stdin (bash -s), so no quoting survives two shells.
  DRVS="$(ssh -o BatchMode=yes "$TIER1_SSH" 'bash -s -- /run/current-system | xargs nix-store -q --deriver 2>/dev/null | grep "\.drv$" | sort -u' <<<"$TUNED_REQUISITES")"
  missing_here() { while read -r d; do [ -e "$d" ] || echo "$d"; done <<<"$DRVS"; }
  if [ -n "$(missing_here)" ]; then
    echo "instantiating $HOST's system here to recreate .drvs it has garbage-collected (~1 min)..."
    nix eval --raw "$FLAKE_ROOT#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" >/dev/null 2>&1 \
      || echo "warning: evaluating $HOST here failed; falling back to the target for every .drv" >&2
  fi
  SHOW='xargs -n 200 nix derivation show 2>/dev/null | jq -s -r "[.[] | .derivations | to_entries[] | (.value.env.pname // .value.structuredAttrs.pname // empty)] | .[]"'
  LOCAL_NAMES="$(while read -r d; do if [ -e "$d" ]; then echo "$d"; fi; done <<<"$DRVS" | bash -c "$SHOW")"
  STILL="$(missing_here)"
  REMOTE_NAMES=""
  if [ -n "$STILL" ]; then
    REMOTE_NAMES="$(ssh -o BatchMode=yes "$TIER1_SSH" "while read -r d; do if [ -e \"\$d\" ]; then echo \"\$d\"; fi; done | $SHOW" <<<"$STILL")"
  fi
  PNAMES="$(printf '%s\n%s\n' "$LOCAL_NAMES" "$REMOTE_NAMES" | grep -v '^$' | sort -u)"
  TOTAL=$(grep -c . <<<"$DRVS"); HERE=$(( TOTAL - $(grep -c . <<<"$STILL" || true) ))
  echo "(closure read on $TIER1_SSH: $TOTAL derivers, $HERE resolved here, rest asked of $TIER1_SSH)"
else
  PNAMES="$(TUNED_REQUISITES="$TUNED_REQUISITES" bash -c "$PNAME_PIPELINE")"
  REMOTE_VERSION=""
fi

NAMES_FILE="$(mktemp)"
trap 'rm -f "$NAMES_FILE"' EXIT
printf '%s\n' "$PNAMES" > "$NAMES_FILE"

# Resolved via builtins.getFlake's own .inputs.nixpkgs, not a raw jq lookup of
# flake.lock's "nixpkgs" JSON key: nix-doom-emacs-unstraightened declares its
# own input literally named "nixpkgs" (a flake-registry fallback), which
# collides with this repo's node name once locked, silently renaming this
# repo's actual nixpkgs fork to "nixpkgs_2" in the lock file. getFlake's
# .inputs is keyed by this flake's own declared input names, immune to that
# JSON-level collision.
NIXPKGS_INFO="$(
  FLAKE_ROOT="$FLAKE_ROOT" nix eval --impure --json --expr '
    let f = builtins.getFlake (builtins.getEnv "FLAKE_ROOT");
    in { inherit (f.inputs.nixpkgs) rev narHash; }
  '
)"
NIXPKGS_REV="$(jq -r '.rev' <<<"$NIXPKGS_INFO")"
NIXPKGS_NARHASH="$(jq -r '.narHash' <<<"$NIXPKGS_INFO")"
# A running system built from another nixpkgs still gets stamped with this
# checkout's -- same as a local refresh after a pull without a rebuild -- so say so.
if [ -n "$REMOTE_VERSION" ] && [[ "$REMOTE_VERSION" != *".${NIXPKGS_REV:0:7}" ]]; then
  echo "warning: $HOST runs $REMOTE_VERSION, this checkout's nixpkgs is ${NIXPKGS_REV:0:7}; rebuild $HOST first for an exact capture" >&2
fi
CAPTURED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export TIER1_FLAKE_ROOT="$FLAKE_ROOT"
export TIER1_NAMES_FILE="$NAMES_FILE"
export TIER1_HOST="$HOST"
export TIER1_NIXPKGS_REV="$NIXPKGS_REV"
export TIER1_NIXPKGS_NARHASH="$NIXPKGS_NARHASH"
export TIER1_CAPTURED_AT="$CAPTURED_AT"

OUT="$DIR/system-tier1.nix"
TMP_OUT="$(mktemp)"

# Bare `nix eval` (no --json/--raw) on a plain data attrset pretty-prints
# valid, re-importable Nix syntax directly -- pnames are already correct by
# this point, so this step is just reading them into Nix syntax, no parsing.
nix eval --impure --expr '
  let
    getEnv = name: builtins.getEnv "TIER1_${name}";
    lib = (builtins.getFlake (getEnv "FLAKE_ROOT")).inputs.nixpkgs.lib;
    lines = lib.splitString "\n" (builtins.readFile (getEnv "NAMES_FILE"));
    pnames = builtins.filter (s: s != "") lines;
  in
  {
    nixpkgsNarHash = getEnv "NIXPKGS_NARHASH";
    nixpkgsRev = getEnv "NIXPKGS_REV";
    host = getEnv "HOST";
    capturedAt = getEnv "CAPTURED_AT";
    runtimeNames = pnames;
  }
' > "$TMP_OUT"
if command -v nixfmt >/dev/null 2>&1; then
  nixfmt "$TMP_OUT"
fi
put_cache "$TMP_OUT" "$OUT"

echo "wrote $OUT ($(wc -l < "$NAMES_FILE") pnames captured via deriver lookup) -- refresh Tier 2 too if package lists changed since the last capture"
