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

  Tier 3: live fallback, full recompute. The classifier walk ITSELF is cheap
  (2.458s for the full ~30-40 anchor set / 1070-package closure, dominated by
  a roughly-fixed nixpkgs-import cost rather than scaling meaningfully with
  anchor count), so no diff/scoping logic; a cache miss just redoes the walk.

  A cold cache is nonetheless worth avoiding on a NEW host, for a reason that
  is NOT evaluation cost -- measured, so it is not a guess:

      cold cache, IFD disabled (pure eval)        12.8s
      warm tier2 copied from a sibling host       30s
      cold cache, IFD enabled, builder down       >20min, never completed

  The walk really is cheap. What is expensive is the knock-on: `hasWarmCache`
  false stops upstream-tools-overlay aliasing to upstream (see its own comment
  on refusing to act on Tier 3 evidence), so the package set differs from every
  existing host -- which means a DIFFERENT emacs, hence a different
  doom-intermediates, hence nix-doom-emacs-unstraightened's import-from-
  derivation has to BUILD it during eval. With a remote builder unreachable
  that build hangs in SSH SYN-SENT, not in evaluation: the nix process sits at
  ~2% CPU blocked on the daemon socket while ssh retries.

  So for a new host: seed the cache first, either with refresh-tier2.sh or --
  if it is a clone of an existing host -- by copying that host's tier2 file and
  changing the `host` field. An identical package set means the IFD output is
  already in the store and nothing needs building.

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

  /*
    Anchors: the union of EVERY feature's packages.nix, plus this host's own
    my.packages.extra. Not the enabled subset -- over-inclusion is the safe
    direction here (see buildOnly's rationale above: an unlisted build tool
    merely gets needlessly tuned, while a dropped runtime dependency causes real
    bugs), and computing the enabled set would need the module fixpoint this
    file exists to avoid.

    Replaces a hand-maintained union that named both hosts explicitly and had a
    bolted-on `kdePackages.kdenlive` anchor for a package no list mentioned.
    Neither survives: features register themselves by existing.

    A feature's packages.nix must reference only plain-nixpkgs attributes --
    freshPkgs is an overlay-free import, deliberately, to dodge the fixpoint
    recursion nixpkgs hits internally once this walks hundreds of packages.
    Anything overlay-provided is wired in the feature's nixos.nix instead.
  */
  featureDir = ../../features;
  featureNames = builtins.attrNames (builtins.readDir featureDir);
  hostsDir = ../../hosts;

  /*
    Read each host's declarations by RAW FUNCTION APPLICATION rather than through
    the module system: the host file is evaluated a second time against an
    independent fixpoint, the same fresh-independent-import technique freshPkgs
    uses to dodge the recursion nixpkgs hits internally. Laziness means only the
    attributes touched below are forced, which is why `config` can be a throw.
  */
  hostMyOf =
    h:
    let
      f = hostsDir + "/${h}/default.nix";
      raw =
        if builtins.pathExists f then
          import f {
            pkgs = freshPkgs;
            inherit lib inputs;
            hostName = h;
            config = throw "lookup.nix: a host file's `my` block must not read `config`";
          }
        else
          { };
    in
    raw.my or { };

  /*
    ANCHOR SCOPE: the union across EVERY host of the features it enables, plus
    every host's my.packages.extra. Host-independent on purpose.

    This reproduces what the hand-written anchor list did -- it named both hosts'
    package lists explicitly -- without keying anything on a hostname. A host
    added tomorrow contributes its own anchors by existing.

    Scope matters more than it looks. Two wrong versions were measured against
    victus-15 (baseline 8417 derivations):

      every feature, enabled or not     8922   (+505: a whole Haskell/pandoc
                                                toolchain)
      only THIS host's features         8861   (churn in both directions)

    The mechanism is indirect and worth stating, because the fail-open reasoning
    that governs `buildOnly` does NOT apply here. That reasoning is about
    TUNING: needlessly tuning a build tool wastes build time and nothing else.
    This signal also drives SUBSTITUTION -- upstream-tools-overlay declines to
    alias anything it believes is host-runtime -- so an over-broad anchor set
    turns a prebuilt download into a from-source compile.
  */
  hostNames = builtins.attrNames (builtins.readDir hostsDir);
  allHostMy = map hostMyOf hostNames;

  enabledIn = my: builtins.filter (n: (my.${n}.enable or false) == true) featureNames;
  enabledFeatures = lib.unique (lib.concatMap enabledIn allHostMy);

  featurePackageSets = builtins.filter (x: x != null) (
    map (
      name:
      let f = featureDir + "/${name}/packages.nix";
      in if builtins.pathExists f then import f { pkgs = freshPkgs; } else null
    ) enabledFeatures
  );
  fromFeatures = lib.concatMap (
    ps: (ps.system or [ ]) ++ (ps.user or [ ]) ++ (ps.home or [ ])
  ) featurePackageSets;

  extrasOf =
    my:
    let
      e = my.packages.extra or { };
    in
    # Reject property-list wrappers EXPLICITLY. A bare `e.system or []` turns
    # mkIf/mkMerge into an EMPTY anchor set with no error at all -- the exact
    # silent blind spot this mechanism exists to close. Measured: wrapping a
    # leaf fails loudly, wrapping the parent returns [] silently.
    if e ? _type then
      throw ''
        lookup.nix: a host file wraps my.packages.extra in ${e._type}
        (mkIf/mkMerge). It must be a literal attrset -- Tier 3 reads it without a
        module evaluation and cannot resolve property lists.''
    else
      lib.concatLists (
        lib.mapAttrsToList (
          n: v:
          if builtins.isList v then
            v
          else
            throw "lookup.nix: my.packages.extra.${n} must be a literal list, got ${v._type or builtins.typeOf v}"
        ) e
      );

  fromHosts = lib.concatMap extrasOf allHostMy;

  tier3Anchors = fromFeatures ++ fromHosts;
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

  /*
    Attribute name -> pname, from the aliasable cache's own attribute walk.

    Every tier records PNAMES -- refresh-tier1.sh reads pname from each store
    path's deriver, tier2/tier3 key their genericClosure on p.pname -- while
    every CALLER asks by top-level ATTRIBUTE NAME: upstream-tools.nix walks
    aliasable `names`, o3.nix and gentoo-lto.nix filter their own lists.

    Where the two differ the classifier held the right answer under a key
    nothing looked up. `pandoc` is recorded as `pandoc-cli`, so
    isHostRuntime "pandoc" was false and upstream-tools replaced a genuinely
    host-runtime package with an untuned upstream build. 490 attributes on this
    host were affected; the map has 3200 entries in total.

    Falls back to an empty map when the aliasable cache is absent or stale, in
    which case behaviour is exactly what it was before -- pname-only matching.
  */
  aliasablePath = ./aliasable.nix;
  aliasable = if builtins.pathExists aliasablePath then import aliasablePath else null;
  attrToPname =
    if aliasable != null && aliasable.nixpkgsNarHash == currentNarHash then
      aliasable.pnames or { }
    else
      { };

  isHostRuntime =
    pkgName:
    let
      n = lib.toLower pkgName;
      # The caller may hand us either spelling, so try both.
      alias = lib.toLower (attrToPname.${pkgName} or attrToPname.${n} or n);
      inAny = k: tier1Set ? ${k} || tier2Set ? ${k} || tier3Set ? ${k};
    in
    inAny n || inAny alias;
in
{
  inherit isHostRuntime hasWarmCache;
  runtimeNames = lib.unique (tier1Names ++ tier2Names ++ tier3Names);
}
