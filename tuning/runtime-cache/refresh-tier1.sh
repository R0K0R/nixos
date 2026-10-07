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

HOST="${1:-$(hostname)}"
if [ ! -d "$FLAKE_ROOT/hosts/$HOST" ]; then
  echo "no hosts/$HOST -- pass an explicit hostname matching a hosts/ directory" >&2
  exit 1
fi

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
echo "resolving pnames via each store path's own deriver (accurate, not a string-pattern guess)..."
# The same pipeline locally or on the TIER1_SSH target; quoted once, so the remote
# shell sees it exactly as the local one would.
PNAME_PIPELINE='nix-store -q --requisites /run/current-system \
  | xargs nix-store -q --deriver 2>/dev/null \
  | grep "\.drv$" \
  | while read -r drv; do [ -e "$drv" ] && echo "$drv"; done \
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
  DRVS="$(ssh -o BatchMode=yes "$TIER1_SSH" 'nix-store -q --requisites /run/current-system | xargs nix-store -q --deriver 2>/dev/null | grep "\.drv$" | sort -u')"
  missing_here() { while read -r d; do [ -e "$d" ] || echo "$d"; done <<<"$DRVS"; }
  if [ -n "$(missing_here)" ]; then
    echo "instantiating $HOST's system here to recreate .drvs it has garbage-collected (~1 min)..."
    nix eval --raw "$FLAKE_ROOT#nixosConfigurations.$HOST.config.system.build.toplevel.drvPath" >/dev/null 2>&1 \
      || echo "warning: evaluating $HOST here failed; falling back to the target for every .drv" >&2
  fi
  SHOW='xargs -n 200 nix derivation show 2>/dev/null | jq -s -r "[.[] | .derivations | to_entries[] | (.value.env.pname // .value.structuredAttrs.pname // empty)] | .[]"'
  LOCAL_NAMES="$(while read -r d; do [ -e "$d" ] && echo "$d"; done <<<"$DRVS" | bash -c "$SHOW")"
  STILL="$(missing_here)"
  REMOTE_NAMES=""
  if [ -n "$STILL" ]; then
    REMOTE_NAMES="$(ssh -o BatchMode=yes "$TIER1_SSH" "while read -r d; do [ -e \"\$d\" ] && echo \"\$d\"; done | $SHOW" <<<"$STILL")"
  fi
  PNAMES="$(printf '%s\n%s\n' "$LOCAL_NAMES" "$REMOTE_NAMES" | grep -v '^$' | sort -u)"
  TOTAL=$(grep -c . <<<"$DRVS"); HERE=$(( TOTAL - $(grep -c . <<<"$STILL" || true) ))
  echo "(closure read on $TIER1_SSH: $TOTAL derivers, $HERE resolved here, rest asked of $TIER1_SSH)"
else
  PNAMES="$(bash -c "$PNAME_PIPELINE")"
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

OUT="$FLAKE_ROOT/tuning/runtime-cache/tier1/$HOST.nix"
# The cache files are gitignored (generated), so this directory does not exist
# in a fresh checkout -- git does not track empty directories.
mkdir -p "$(dirname "$OUT")"

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
' > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
if command -v nixfmt >/dev/null 2>&1; then
  nixfmt "$OUT"
fi

echo "wrote $OUT ($(wc -l < "$NAMES_FILE") pnames captured via deriver lookup) -- refresh Tier 2 too if package lists changed since the last capture"
