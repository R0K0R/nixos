/*
  Three-tier host-runtime lookup. Replaces host-runtime-classifier.nix's own
  logic (that file is now a thin wrapper around this). See the plan this was
  built from for the full design rationale:
  /home/r0k0r/.claude/plans/temporal-crafting-parnas.md

  Tier 1 (tier1/<host>.nix, via refresh-tier1.sh): the REAL live system
  closure (`nix-store -q --requisites /run/current-system`) -- ground truth,
  but only knows about what's already been switched to.

  Tier 2 (tier2/<host>.nix, via refresh-tier2.sh + tier2-eval.nix): a cached
  eval-time heuristic, closes the gap for packages added but not yet
  switched-to.

  Tier 3: live fallback, full recompute -- confirmed empirically cheap
  (2.458s for the full ~30-40 anchor set / 1070-package closure, dominated by
  a roughly-fixed nixpkgs-import cost rather than scaling meaningfully with
  anchor count), so no diff/scoping logic; a cache miss just redoes the whole
  walk. Same anchor source (user-packages.nix) and fresh-independent-import
  technique host-runtime-classifier.nix already used, to avoid the fixpoint
  infinite recursion nixpkgs hits internally (by-name-overlay.nix,
  aliases.nix) once this walks hundreds of packages.

  Both cache tiers are monotonic positive evidence only: absence never
  asserts "not host-runtime," only "not yet known here" -- Tier 1 can't know
  about a package before a real switch, so falling through to Tier 2/3 is
  the intended behavior, not a bug.

  Invalidation: each cache file records the nixpkgsNarHash it was captured
  against. A cache whose narHash doesn't match the currently-evaluated
  flake's nixpkgs input is treated as fully stale and skipped entirely --
  deliberately coarse (whole-cache, not per-package) rather than per-package
  hash comparison, since Nix's content-addressed hashing means nearly every
  package's own hash changes on any nixpkgs bump regardless of whether its
  actual runtime-reachability changed, so per-package invalidation would
  provide near-zero real caching benefit.

  buildOnly is applied uniformly across all three tiers, not just Tier 2/3:
  the risk it guards against (a shared top-level attribute getting O3/LTO
  flags that then SIGILL when the same derivation is invoked as build
  machinery on a different-arch remote builder -- already hit twice in this
  fork, kdsoap-ws-discovery-client and rnnoise-plugin/juce_lv2_helper) is a
  property of the package itself, not of which tier happened to observe it
  as reachable.
*/
{
  inputs,
  system ? "x86_64-linux",
  host,
}:
let
  lib = inputs.nixpkgs.lib;

  # Packages that only ever run on a builder, never on this host. Fail-open
  # by design -- see tier2-eval.nix's copy of this same list and rationale
  # (carried over from runtime-closure.nix, the file this design supersedes).
  buildOnly = [
    "ccache"
    "mold"
    "mold-unwrapped-wrapper"
    "autoconf"
    "automake"
    "libtool"
    "cmake"
    "meson"
    "ninja"
    "pkg-config"
    "bison"
    "flex"
    "gperf"
    "help2man"
    "texinfo"
  ];
  # Sets (attrsets keyed by name, `?` for membership) rather than lists +
  # builtins.elem: isHostRuntime gets called once per top-level nixpkgs
  # attribute by host-upstream-substitute-overlay.nix (~27683 calls per
  # eval). builtins.elem is a linear scan -- against tier1/tier2 lists with
  # 1000+ entries each, that's tens of millions of comparisons and measured
  # to cost over a minute of eval time on its own. Attrset lookup is O(1).
  # Names on the query side (isHostRuntime's argument, always a top-level
  # nixpkgs attribute name from upstream-tools-overlay.nix's builtins.attrNames
  # walk) are already lowercase by nixpkgs convention. Names on the storage
  # side are NOT guaranteed to match: Tier 3's closure walk keys packages by
  # `.pname`, which preserves upstream projects' own capitalization (e.g.
  # kddockwidgets' pname is "KDDockWidgets" while its nixpkgs attribute name
  # is "kddockwidgets") -- a case mismatch here is a silent false negative,
  # confirmed concretely: it caused kddockwidgets to be misclassified as not
  # host-runtime, which let upstream-tools-overlay substitute it from
  # upstream, pulling in upstream's own qtbase and producing a real "mismatched
  # Qt dependencies" build failure against kdenlive's host-tuned qtbase.
  # Lowercase-normalizing both the storage and query sides here fixes this
  # for all three tiers without needing to touch how each tier's raw names
  # are captured.
  toSet = names: lib.genAttrs (map lib.toLower names) (_: true);
  buildOnlySet = toSet buildOnly;
  dropBuildOnly = names: lib.filter (n: !(buildOnlySet ? ${n})) names;

  currentNarHash = inputs.nixpkgs.narHash;

  tier1Path = ./tier1 + "/${host}.nix";
  tier2Path = ./tier2 + "/${host}.nix";

  tier1 = if builtins.pathExists tier1Path then import tier1Path else null;
  tier2 = if builtins.pathExists tier2Path then import tier2Path else null;

  tier1Valid = tier1 != null && tier1.nixpkgsNarHash == currentNarHash;
  tier2Valid = tier2 != null && tier2.nixpkgsNarHash == currentNarHash;
  # Exposed for consumers where a Tier 3-only (no cache) answer isn't safe to
  # act on silently -- e.g. host-upstream-substitute-overlay.nix, where a
  # false negative doesn't just skip an optimization (cheap) but replaces a
  # package outright, potentially discarding a genuine functional patch
  # (confirmed concretely: on a cold cache, both `mesa` and `libfprint` --
  # the latter carrying a fingerprint-auth-enabling patch, not just a
  # pseudo-cross compatibility fix -- come back false under Tier 3 alone).
  hasWarmCache = tier1Valid || tier2Valid;

  tier1Names = if tier1Valid then dropBuildOnly tier1.runtimeNames else [ ];
  tier2Names =
    if tier2Valid then
      # tier2.candidates is already buildOnly-filtered by tier2-eval.nix,
      # but re-filtering here is cheap and keeps this file self-contained.
      dropBuildOnly tier2.candidates
    else
      [ ];

  # Tier 3, computed lazily -- only actually forced if isHostRuntime/
  # runtimeNames genuinely need it (a name absent from both caches).
  freshPkgs = import inputs.nixpkgs { inherit system; };
  up = import ../../packages/user-packages.nix { pkgs = freshPkgs; };
  tier3Anchors =
    up.system.common
    ++ up.system.galaxybook4-pro360
    ++ up.system."victus-15"
    ++ up.account.common
    ++ up.account.galaxybook4-pro360
    ++ up.homeManager.common
    ++ [ freshPkgs.kdePackages.kdenlive ];
  keyOf = pkg: pkg.pname or pkg.name or "unknown";
  tier3Closure = builtins.genericClosure {
    startSet = map (pkg: {
      key = keyOf pkg;
      inherit pkg;
    }) tier3Anchors;
    operator =
      { pkg, ... }:
      map (p: {
        key = keyOf p;
        pkg = p;
      }) (
        builtins.filter (p: p ? pname || p ? name) (
          (pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ])
        )
      );
  };
  tier3Names = dropBuildOnly (lib.unique (map (item: item.key) tier3Closure));

  # Built lazily from the (already-lazy) *Names lists -- forcing tier3Set
  # still only happens if isHostRuntime genuinely needs Tier 3 at all, same
  # as before; this only changes membership testing from O(n) to O(1) once
  # a tier is actually consulted.
  tier1Set = toSet tier1Names;
  tier2Set = toSet tier2Names;
  tier3Set = toSet tier3Names;

  isHostRuntime =
    pkgName:
    let
      n = lib.toLower pkgName;
    in
    tier1Set ? ${n} || tier2Set ? ${n} || tier3Set ? ${n};
in
{
  inherit isHostRuntime hasWarmCache;
  runtimeNames = lib.unique (tier1Names ++ tier2Names ++ tier3Names);
}
