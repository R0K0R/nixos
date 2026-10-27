/*
  sccache across the tuned host set's Rust packages (my.ccache.rust).

  SELECTION is `rustPlatform` in the tuned host splice, not a list of names.
  Cross-package reuse grows with the number of packages sharing the cache, so
  all of them, and every host-splice derivation already differs from upstream
  (gccarch), so the rebuild a changed hook costs is one the switch pays anyway.
  The same guard as heavy.nix keeps it off everything else:

    - the build splice (hostPlatform == buildPlatform, no gcc.arch): build
      tools stay byte-identical to upstream and substitute;
    - packages upstream-tools.nix aliases into the host splice: they are
      `upstream.<name>` from a fresh import of nixpkgs-upstream, which never
      sees this overlay, so they stay on cache.nixos.org;
    - native mode (march = null): the host set IS upstream there;
    - pkgsStatic/pkgsMusl and the bootstrap stages.

  Why rustPlatform and not the stdenv swap heavy.nix does per name: most Rust
  packages take `rustPlatform`, not `stdenv`, so heavy's `takes pkg "stdenv"`
  test leaves them alone -- and the classifier's names would not find them
  any better. One attribute override reaches every
  `rustPlatform.buildRustPackage` in the tuned set; the override goes through
  the host set's callPackage auto-arguments, and buildRustPackage is a function,
  which splicing passes through from the host set unchanged.

  NOT COVERED, deliberately: packages that list the cargo hooks themselves
  (librsvg and the meson + cargo GNOME apps, maturin/setuptools-rust Python
  packages). The hook they list is the spliced build-platform one (see
  features/nix/ccache/sccache.nix), so reaching them means per-package
  overrideAttrs -- python3Packages is a scope heavy.nix does not touch either.
  Also `rustPackages_<ver>.rustPlatform` and `makeRustPlatform` users, which
  are rare. They build exactly as before.
*/
{
  lib,
  cacheDir,
}:

final: prev:
if
  builtins.match ".*bootstrap.*" (prev.stdenv.name or "") != null
  || ((prev.stdenv.hostPlatform.gcc or { }).arch or "") == ""
  || (prev.stdenv.hostPlatform.isStatic or false)
  || (prev.stdenv.hostPlatform.isMusl or false)
then
  { }
else
  let
    sccache = import ../../features/nix/ccache/sccache.nix {
      inherit lib;
      inherit (prev) buildPackages;
    } { inherit cacheDir; };
  in
  {
    rustPlatform = sccache.wrapRustPlatform prev.rustPlatform;
  }
