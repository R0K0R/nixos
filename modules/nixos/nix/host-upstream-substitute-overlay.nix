/*
  Sibling of upstream-tools-overlay.nix, for the HOST (tuned) splice instead
  of the build splice: substitutes packages from unpatched upstream nixpkgs
  when they exist in the host-tuned pkgs set but AREN'T genuinely
  host-runtime (per hostRuntimeClassifier.isHostRuntime) -- i.e. they gain
  nothing from being part of the patched pseudo-cross tree (o3-overlay.nix/
  gentoo-lto-overlay.nix only ever tune isHostRuntime=true candidates) but
  still pay the "must build through the patched toolchain, can't substitute
  from cache.nixos.org" cost for zero benefit.

  WHY THIS IS SAFE: every concrete pseudo-cross bug hit in this fork --
  Qt6 native-tool lookups, kdsoap SIGILL, embree's ISA-dispatch confusion,
  Qt5's F16C detection, jasper's C17 sentinel -- is about the BUILD PROCESS
  failing or misbehaving under pseudo-cross conditions, never about the
  finished artifact behaving differently at runtime. Substituting sidesteps
  that whole bug class structurally: the package is never built under
  pseudo-cross at all, not even on a cache miss (aliasing to
  nixpkgs-upstream falls back to building from a completely separate, plain
  nixpkgs import with no gcc.arch, no fork patches, no cross machinery --
  same reasoning upstream-tools-overlay.nix already relies on for the build
  splice). Host-splice packages also carry identical --host=/--build=
  strings (same triple; this fork's whole intra-ISA premise), so a package
  that DID successfully build under pseudo-cross would take the same
  native-detection code path as plain upstream anyway.

  TRADEOFF ACCEPTED: closure duplication. A substituted package's own
  dependencies come from nixpkgs-upstream too, so a shared library can end
  up with two copies in the closure -- the tuned one used by genuinely-tuned
  packages, and upstream's untuned one used by everything substituted here.
  Not a correctness issue, just storage -- already the accepted norm for the
  build splice (91% of the toplevel closure there, per that file's own
  measurement). Explicitly worth it here: 1TB disk, zstd store compression,
  trading storage for not needlessly building through the patched toolchain.

  pkgsStatic EXCLUSION: confirmed empirically this session that pkgsStatic
  ALSO carries hostPlatform.gcc.arch (same CPU, just statically linked) --
  unlike pkgsMusl/pkgsi686Linux/buildPlatform, which don't. A bare
  arch-presence guard would therefore also match pkgsStatic and incorrectly
  alias its packages to upstream's dynamically-linked build. Excluded via
  hostPlatform.isStatic.

  TWO ADDITIONAL SAFETY LAYERS, both added after the "safe because it's only
  about buildability" argument above turned out to be incomplete:

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
     like that wouldn't just skip an optimization (the failure mode this
     overlay's sibling, o3-overlay.nix, safely tolerates) -- it would
     silently replace the package outright, discarding the patch with zero
     error anywhere. victus-15 has no per-package overrides at all
     (confirmed via the same grep), so nothing to add there today, but this
     list needs a manual look whenever a new per-host override is added.
     Nested-scope overrides (kdePackages.*, qt5.*, qt6.*, qt6Packages.*,
     perlPackages.*, python3Packages.*) don't need listing here: they aren't
     derivations themselves, so isDrvIn already excludes them structurally.

  2. hasWarmCache gate -- confirmed empirically that on a cold cache (no
     Tier 1 or Tier 2 data for this host, e.g. a genuinely new environment
     before any refresh script has run), Tier 3's classification of BOTH
     mesa and libfprint comes back false. Rather than silently substituting
     based on that weaker answer, this overlay does nothing at all when
     hasWarmCache is false, and says so via lib.warn so the reason a rebuild
     doesn't have the storage-saving substitution is visible instead of
     silent.
*/
{
  lib,
  inputs,
  hostRuntimeClassifier,
  system ? "x86_64-linux",
  excludePatterns ? [
    "stdenv"
    "emulatorhook"
  ],
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
  # Hard exclusion, independent of isHostRuntime -- see header comment.
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
  # Fresh imports, never `prev` -- same infinite-recursion hazard and same
  # workaround as upstream-tools-overlay.nix and host-runtime-classifier.nix.
  fork = import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  upstream = import inputs.nixpkgs-upstream {
    inherit system;
    config.allowUnfree = true;
  };

  isDrvIn =
    set: n:
    let
      r = builtins.tryEval (lib.isDerivation (set.${n} or null));
    in
    r.success && r.value;

  lower = lib.toLower;

  # Identical to upstream-tools-overlay.nix's own test and rationale: a
  # package whose binaries are named for a target (targetPrefix) can't be
  # safely aliased regardless of runtime status.
  isTargetAware =
    n:
    let
      r = builtins.tryEval ((fork.${n}.targetPrefix or null) != null);
    in
    r.success && r.value;

  keepable =
    n:
    !(builtins.elem n excludeNames)
    && !(builtins.elem n knownPatchedNames)
    && !(lib.any (p: lib.hasInfix p (lower n)) excludePatterns)
    && isDrvIn fork n
    && isDrvIn upstream n
    && !(isTargetAware n)
    && !(hostRuntimeClassifier.isHostRuntime n);

  aliasNames = builtins.filter keepable (builtins.attrNames fork);
in

final: prev:

if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
  || (prev.stdenv.hostPlatform.isStatic or false)
then
  { }
else if !hostRuntimeClassifier.hasWarmCache then
  lib.warn
    "host-upstream-substitute-overlay: no valid Tier 1/Tier 2 runtime-cache data for this host (cold cache or nixpkgs revision changed since it was captured) -- skipping substitution entirely rather than trusting Tier 3's weaker anchor coverage for a destructive action. Run refresh-tier2.sh (and refresh-tier1.sh after a switch) to enable it."
    { }
else
  builtins.listToAttrs (
    map (name: {
      inherit name;
      value = upstream.${name};
    }) aliasNames
  )
