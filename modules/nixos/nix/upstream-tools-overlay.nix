/*
  Source BUILD-platform packages from unpatched upstream nixpkgs so they
  substitute from cache.nixos.org instead of being rebuilt through the fork.

  WHY THIS WORKS WITHOUT A RUNTIME CLASSIFIER
  -------------------------------------------
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

  EVAL COST: ~25s for the attribute walk (27683 attrs, tryEval-guarded).
*/
{
  lib,
  inputs,
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

  keepable =
    n:
    !(builtins.elem n excludeNames)
    && !(lib.any (p: lib.hasInfix p (lower n)) excludePatterns)
    && isDrvIn fork n
    && isDrvIn upstream n
    && !(isTargetAware n);

  aliasNames = builtins.filter keepable (builtins.attrNames fork);
in

final: prev:

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
if prev.stdenv.hostPlatform != prev.stdenv.buildPlatform then
  { }

# nixpkgs re-evaluates the whole overlay list per bootstrap stage; swapping
# packages underneath a half-built stdenv is how the m4 failure documented in
# gentoo-lto-overlay.nix began.
else if builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null then
  { }

else
  builtins.listToAttrs (
    map (name: {
      inherit name;
      value = upstream.${name};
    }) aliasNames
  )
