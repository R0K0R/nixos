/*
  Source packages from unpatched upstream nixpkgs so they substitute from
  cache.nixos.org instead of being rebuilt through the fork -- on BOTH the
  build splice (always safe, no runtime check needed) and the host splice
  (only for packages that aren't genuinely host-runtime).

  WHY BUILD-SPLICE ALIASING WORKS WITHOUT A RUNTIME CLASSIFIER
  --------------------------------------------------------------
  In a cross build the same package name yields two distinct derivations:
  pkgsBuildHost.<x> (BUILD platform, runs on the builder) and pkgs.<x> (HOST
  platform, runs on this machine). The platform split IS the build-time vs
  runtime distinction, so applying the alias only to the BUILD splice gives
  "upstream when it's a build tool, march'd when it's something we run" for
  free -- no name-based classification, and no pessimism from a name that is
  runtime-reachable somewhere but a pure build tool here. An earlier version
  filtered by a runtime closure instead and left ~900 more derivations building,
  precisely because it decided per *name* rather than per *use*.

  The fork and nixpkgs-upstream are pinned to the SAME revision (the fork is a
  patch series on top of it), so this swaps "with the fork's 57-file patch set"
  for "without it", not between two different trees. There is no version skew.

  Discarding the fork's patches on the BUILD side is safe because those patches
  exist to make packages *build* under pseudo-cross -- and here we are not
  building them, we are substituting them prebuilt. Even on a cache miss,
  upstream's package set is plain native, so pseudo-cross never enters into it.
  Patches that shape *other* packages' builds live in wrappers, stdenv, and
  builder functions (mk-python-derivation, qtModule, mk-kde-derivation), none of
  which are aliasable top-level derivations, and the wrappers are excluded below.

  Measured on galaxybook4-pro360: 4280 -> 2370 derivations to build (-45%), with
  download rising only 2.2 -> 2.6 GiB. The remainder is ~1570 host-platform
  (march'd, irreducible by design) plus ~300 NixOS-config-generated artifacts
  that Hydra never had -- i.e. close to the practical floor.

  NOT DONE: recursing into scoped package sets (qt6, libsForQt5, texlive) by
  replacing whole scopes. It evaluates and is internally consistent, but bought
  only 66 further derivations (2.8%) while swapping entire Qt package sets --
  the category most linked into what we actually ship. Poor risk-adjusted trade.

  WHY THE HOST SPLICE NEEDS A RUNTIME CHECK (packages this file merged in
  from the former host-upstream-substitute-overlay.nix)
  --------------------------------------------------------------
  Host-splice packages ARE genuinely part of the pseudo-cross build graph
  (unlike the build splice, hostPlatform.gcc.arch is set here), so they can't
  be aliased unconditionally the way build-splice packages can -- only the
  ones that gain nothing from staying in the patched tree, i.e. aren't
  genuinely host-runtime (o3-overlay.nix/gentoo-lto-overlay.nix only ever
  tune isHostRuntime=true candidates, so an isHostRuntime=false package pays
  the "must build through the patched toolchain" cost for zero benefit).

  WHY THIS IS SAFE: every concrete pseudo-cross bug hit in this fork --
  Qt6 native-tool lookups, kdsoap SIGILL, embree's ISA-dispatch confusion,
  Qt5's F16C detection, jasper's C17 sentinel -- is about the BUILD PROCESS
  failing or misbehaving under pseudo-cross conditions, never about the
  finished artifact behaving differently at runtime. Substituting sidesteps
  that whole bug class structurally: the package is never built under
  pseudo-cross at all, not even on a cache miss (falls back to building from
  nixpkgs-upstream, plain native, no gcc.arch, no fork patches). Host-splice
  packages also carry identical --host=/--build= strings (same triple; this
  fork's whole intra-ISA premise), so a package that DID successfully build
  under pseudo-cross would take the same native-detection code path as plain
  upstream anyway.

  TRADEOFF ACCEPTED: closure duplication. A substituted package's own
  dependencies come from nixpkgs-upstream too, so a shared library can end
  up with two copies in the closure -- the tuned one used by genuinely-tuned
  packages, and upstream's untuned one used by everything substituted here.
  Not a correctness issue, just storage -- already the accepted norm for the
  build splice (91% of the toplevel closure there, per the measurement
  above). Explicitly worth it: 1TB disk, zstd store compression, trading
  storage for not needlessly building through the patched toolchain.

  pkgsStatic EXCLUSION: confirmed empirically that pkgsStatic ALSO carries
  hostPlatform.gcc.arch (same CPU, just statically linked) -- unlike
  pkgsMusl/pkgsi686Linux/buildPlatform, which don't. A bare arch-presence
  guard would therefore also match pkgsStatic and incorrectly alias its
  packages to upstream's dynamically-linked build. Excluded via
  hostPlatform.isStatic.

  TWO ADDITIONAL SAFETY LAYERS ON THE HOST-SPLICE SIDE, both added after the
  "safe because it's only about buildability" argument above turned out to
  be incomplete:

  1. knownPatchedNames -- a hard exclusion list, independent of
     isHostRuntime, for every top-level package this fork gives a per-host
     custom override to (galaxybook4-pro360/default.nix, grepped directly
     rather than from memory: mesa, libfprint, xapian_1_4, libosinfo,
     openldap, embree, jasper, nodejs-slim_24, nodejs_24, sdl3, frei0r,
     nixfmt, rnnoise-plugin, easyeffects, zam-plugins). Some of these carry
     GENUINE FUNCTIONAL patches, not just pseudo-cross build fixes --
     libfprint's is the concrete example: it adds SDCP support so fingerprint
     enrollment actually persists to the sensor, which upstream's driver
     silently fails to do. A false-negative from isHostRuntime on a package
     like that wouldn't just skip an optimization (the failure mode
     o3-overlay.nix safely tolerates) -- it would silently replace the
     package outright, discarding the patch with zero error anywhere.
     victus-15 has no per-package overrides at all (confirmed via the same
     grep), so nothing to add there today, but this list needs a manual look
     whenever a new per-host override is added. Nested-scope overrides
     (kdePackages.*, qt5.*, qt6.*, qt6Packages.*, perlPackages.*,
     python3Packages.*) don't need listing here: they aren't derivations
     themselves, so isDrvIn already excludes them structurally.

  2. hasWarmCache gate -- confirmed empirically that on a cold cache (no
     Tier 1 or Tier 2 data for this host, e.g. a genuinely new environment
     before any refresh script has run), Tier 3's classification of BOTH
     mesa and libfprint comes back false. Rather than silently substituting
     based on that weaker answer, host-splice aliasing does nothing at all
     when hasWarmCache is false, and says so via lib.warn so the reason a
     rebuild doesn't have the storage-saving substitution is visible instead
     of silent.

  EVAL COST / WHY THIS IS ONE FILE, NOT TWO: build-splice and host-splice
  aliasing used to be separate overlays, each doing its own fork/upstream
  import and its own isDrvIn/isTargetAware walk over all ~27683 top-level
  nixpkgs attributes. Measured cost of that duplication: evaluating
  environment.systemPackages went from ~44s to ~67s real time once the
  second overlay existed -- i.e. paying the ~25s attribute walk (itself
  already documented, pre-existing, in this file) a second time. Merged
  into one shared walk here: fork/upstream are imported once,
  isDrvIn/isTargetAware/exclusions run once per attribute, and both splices'
  alias lists are filtered from that single result.
*/
{
  lib,
  inputs,
  hostRuntimeClassifier,
  system ? "x86_64-linux",
  /*
    Two exclusions the target-awareness test below cannot express, because they
    are not packages that target a platform -- they ARE platform machinery:

      *stdenv*        a foreign stdenv is an entire alternate fixpoint. This was
                      the sole cause of the "infinite recursion encountered"
                      that made an earlier attempt look structurally impossible;
                      bisection pinned it to gccCrossLibcStdenv.
      *EmulatorHook*  asserts on canExecute, which pseudo-cross inverts:
                      "mesonEmulatorHook may only be added to nativeBuildInputs
                      when the target binaries can't be executed".
  */
  excludePatterns ? [
    "stdenv"
    "emulatorhook"
  ],
  /*
    stdenv's initialPath. Not target-aware, so not caught below, and in practice
    aliasing them is a no-op (the fork does not patch them, so its build-platform
    copies are already upstream-identical). Kept as cheap insurance: these feed
    stdenv construction, and nixpkgs re-evaluates the overlay list per bootstrap
    stage.
  */
  excludeNames ? [
    "coreutils"
    "findutils"
    "diffutils"
    "gnused"
    "gnugrep"
    "gawk"
    "gnutar"
    "gzip"
    "bzip2"
    "gnumake"
    "bash"
    "patch"
    "xz"
    "file"
    "patchelf"
  ],
  # Hard exclusion for the host splice only, independent of isHostRuntime --
  # see header comment.
  knownPatchedNames ? [
    "mesa"
    "libfprint"
    "xapian_1_4"
    "libosinfo"
    "openldap"
    "embree"
    "jasper"
    "nodejs-slim_24"
    "nodejs_24"
    "sdl3"
    "frei0r"
    "nixfmt"
    "rnnoise-plugin"
    "easyeffects"
    "zam-plugins"
  ],
}:

let
  # Fresh imports, never the overlay's own `prev`: forcing `prev` mid-overlay
  # chain triggers genuine infinite recursion inside nixpkgs' internals
  # (by-name-overlay.nix, aliases.nix). Same technique host-runtime-classifier
  # uses and for the same reason.
  fork = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  upstream = import inputs.nixpkgs-upstream {
    inherit system;
    config.allowUnfree = true;
  };

  # nixpkgs has thousands of attributes that throw on access (renamed, removed,
  # unsupported-platform aliases). tryEval keeps the walk total.
  isDrvIn =
    set: n:
    let
      r = builtins.tryEval (lib.isDerivation (set.${n} or null));
    in
    r.success && r.value;

  lower = lib.toLower;

  /*
    Target-awareness test -- the derived rule, replacing a hand-written list of
    name prefixes that had to be extended five times, each time by something
    breaking mid-build (stdenv, EmulatorHook, the wrappers, bintools, mold).

    A package must not be imported from another package set if it is a *tool that
    targets a platform*, because its binaries are named for that target. From
    pkgs/build-support/{cc,bintools,pkg-config}-wrapper/default.nix:

      targetPrefix = optionalString (targetPlatform != hostPlatform)
                       (targetPlatform.config + "-");
      pname = targetPrefix + ...;

    So a cross toolchain ships x86_64-unknown-linux-gnu-ld.mold while upstream's
    native build ships only bare ld.mold -- which is precisely how aliasing mold
    left the cross bintools-wrapper pointing at a file that does not exist. The
    same wrappers publish targetPrefix in passthru, so the property is directly
    queryable rather than inferred from the name.

    Catches 63 attributes: the whole toolchain (bintools*, binutils*, gcc*,
    clang*, gccgo*, gfortran*, gnat*, flang*, ghc, mold, mold-wrapped,
    pkg-config, pkgconf, cctools, emscripten, arocc, wild, ccacheWrapper,
    distccWrapper, ...). Both packages that broke builds are in it. It does NOT
    catch molden, lldb, lldap or lldpd, which the "mold"/"lld" prefix guesses
    wrongly swept up.

    Costs nothing extra: `fork` is already imported for the derivation check.
  */
  isTargetAware =
    n:
    let
      r = builtins.tryEval ((fork.${n}.targetPrefix or null) != null);
    in
    r.success && r.value;

  # Shared structural filter -- computed ONCE, used for BOTH splices (this is
  # the ~25s walk; see EVAL COST in the header comment for why this matters).
  structurallyKeepable =
    n:
    !(builtins.elem n excludeNames)
    && !(lib.any (p: lib.hasInfix p (lower n)) excludePatterns)
    && isDrvIn fork n
    && isDrvIn upstream n
    && !(isTargetAware n);

  # Cached via runtime-cache/refresh-aliasable.sh: this is the expensive part
  # (fork+upstream imports, then the walk above over ~27683 attributes) --
  # host-independent, since none of it touches hostRuntimeClassifier, so one
  # cache file covers both hosts. Unlike the runtime-cache tiers, a missing
  # or stale cache here has no correctness implication -- structural
  # aliasability doesn't depend on live/runtime state, only on this exact
  # nixpkgs revision -- so falling back to live computation is always safe,
  # just slower. No lib.warn needed for that reason.
  aliasableCachePath = ../runtime-cache/aliasable.nix;
  aliasableCache = if builtins.pathExists aliasableCachePath then import aliasableCachePath else null;
  aliasableCacheValid = aliasableCache != null && aliasableCache.nixpkgsNarHash == inputs.nixpkgs.narHash;

  structurallyKeepableNames =
    if aliasableCacheValid then
      aliasableCache.names
    else
      builtins.filter structurallyKeepable (builtins.attrNames fork);

  # Build splice: every structurally-keepable name. No runtime check needed --
  # pkgsBuildHost is never anything but a build tool by construction.
  buildAliasNames = structurallyKeepableNames;

  # Host splice: same names, minus the hard exclusion list and minus anything
  # genuinely host-runtime.
  knownPatchedSet = lib.genAttrs knownPatchedNames (_: true);
  hostAliasNames = builtins.filter (
    n: !(knownPatchedSet ? ${n}) && !(hostRuntimeClassifier.isHostRuntime n)
  ) structurallyKeepableNames;

  aliasAttrs = names: builtins.listToAttrs (map (name: { inherit name; value = upstream.${name}; }) names);
in

final: prev:

# nixpkgs re-evaluates the whole overlay list per bootstrap stage; swapping
# packages underneath a half-built stdenv is how the m4 failure documented in
# gentoo-lto-overlay.nix began.
if builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null then
  { }

# Only the BUILD platform, identified as hostPlatform == buildPlatform.
#
# It is NOT enough to test for the absence of gcc.arch. nixpkgs instantiates
# more package sets than just host and build: pkgsMusl, pkgsStatic, pkgsi686Linux
# and friends are further cross sets that also lack gcc.arch, so an
# arch-absence test matches them too and injects native glibc x86_64-linux
# packages into, say, a musl cross set. That is what it does -- observed as
# x86_64-unknown-linux-musl-gcc failing to build, pulled in by Hyprland's
# security-wrapper and stub-ld via pkgsStatic.
#
# hostPlatform == buildPlatform is true only for the genuine BUILD set:
#   HOST  gnu/meteorlake -> gnu          differ (elaborated attrs differ by gcc.arch)
#   BUILD gnu            -> gnu          equal   <- the only one we alias
#   MUSL  musl           -> gnu          differ
else if prev.stdenv.hostPlatform == prev.stdenv.buildPlatform then
  aliasAttrs buildAliasNames

# The genuine tuned host splice only -- excludes pkgsStatic (see header) and
# pkgsMusl/pkgsi686Linux (which fail the arch-presence half of this check
# already, since only the real host splice carries gcc.arch here).
else if
  ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == "" || (prev.stdenv.hostPlatform.isStatic or false)
then
  { }
else if !hostRuntimeClassifier.hasWarmCache then
  lib.warn
    "upstream-tools-overlay (host splice): no valid Tier 1/Tier 2 runtime-cache data for this host (cold cache or nixpkgs revision changed since it was captured) -- skipping host-splice substitution entirely rather than trusting Tier 3's weaker anchor coverage for a destructive action. Run refresh-tier2.sh (and refresh-tier1.sh after a switch) to enable it."
    { }
else
  aliasAttrs hostAliasNames
