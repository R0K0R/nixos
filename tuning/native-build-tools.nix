/*
  NATIVE MODE ONLY (o3/lto with march = null): which tuning candidates a build
  tool links, and so must NOT be tuned natively.

  WHY THIS EXISTS. With march, a package name is two derivations: the
  host splice (tuned, runs here) and pkgsBuildHost (upstream, runs on the
  builder). Tuning openssl touches only the first, so python3-as-a-build-tool
  never notices. Natively there is one package set and one openssl: tuning it
  rebuilds python3, perl, curl, git -- every build tool that links it -- and,
  through them, every package that merely BUILDS with one of them. Measured on
  galaxybook4-pro360 with only the classifier as filter (2026-10-17): 2913
  derivations changed outputs, among them python3, perl, meson, clang, a full
  gcc-16.2.0 (gnum4 -> gmp -> gcc) and eight stdenvs. The roots were 24
  tuned packages; ncurses, openssl, util-linux and gnum4 caused nearly all of
  it.

  Aliasing build tools back to the untuned baseline (upstream-tools.nix NATIVE
  MODE) cannot fix that on its own: python3 and perl are host-runtime too --
  installed, or linked by something installed -- so the classifier keeps them
  in the tuned fixpoint, and a name cannot be "tuned here, untuned there"
  without a split.

  So natively the line is drawn on the other side: a candidate in the runtime
  closure (buildInputs + propagatedBuildInputs, the same edges the classifier
  walks) of any of the seed build tools below is left untuned. What remains --
  codecs, numerics, image and font libraries, the GUI stack -- is linked by
  applications, not by the toolchain, so tuning it rebuilds applications and
  nothing that builds them.

  THE SEEDS are the classifier's own buildOnly list (lookup.nix) plus the
  interpreters and compilers that packages put in nativeBuildInputs. A tool
  missing here does not break anything: it means that tool is rebuilt against
  the tuned libraries (and loses substitution) instead of the library staying
  untuned. The `lto`-alone matrix variant's closure diff against `off` is the
  check that the list is complete enough -- see tuning/nixos.nix.

  Keys are lowercased pnames, as in lookup.nix, so `curlMinimal` (pname curl)
  and `curl` are one entry: conservative in the safe direction.

  Imported from nixpkgs-upstream, overlay-free, for the same recursion reason
  lookup.nix gives for freshPkgs. Native mode always runs on upstream
  (flake.nix forkWanted), so this is the tree the host actually uses.
*/
{
  inputs,
  lib,
  system ? "x86_64-linux",
  seeds ? [
    # lookup.nix buildOnly
    "ccache" "mold" "autoconf" "automake" "libtool" "cmake" "meson" "ninja"
    "pkg-config" "bison" "flex" "gperf" "help2man" "texinfo"
    # interpreters, compilers and fetchers in nativeBuildInputs everywhere
    "python3" "perl" "gnum4" "gettext" "git" "curl" "curlMinimal" "gnumake"
    "llvmPackages.clang" "llvmPackages.llvm" "rustc" "cargo" "go"
    # nodejs is a symlinkJoin whose buildInputs warn-redirect to nodejs-slim's
    # (lookup.nix has the same special case), so name the real ones
    "nodejs-slim" "nodejs-slim_latest"
    "gobject-introspection" "wayland-scanner" "glib" "libxslt" "docbook-xsl-nons"
    "doxygen" "sphinx" "gtk-doc" "intltool" "makeWrapper" "patchelf" "jdk"

    # Each found by the lto/o3-alone vs all-off closure diff (2026-10-17):
    # protoc is a build tool; o3 tuning abseil-cpp under it rebuilt protobuf
    "protobuf"
    # cargo-setup-hook runs diffutils' cmp; o3 lists diffutils
    "diffutils"
    # util-linuxMinimal (libuuid, in python3's closure) is an .override of
    # util-linux, so it inherits util-linux's tuning under a different pname
    "util-linux"
    # jq runs inside build hooks (npm-install-hook): tuning its oniguruma
    # rebuilt furo -> tox -> distutils, i.e. setuptools' own test closure
    "jq"
    # numpy is in the build and check inputs of half of python3Packages:
    # tuning openblas under it rebuilt pybind11, scikit-build-core, black and
    # pdm-backend (via mercurial's tests). numpy reaches openblas only through
    # the blas/lapack wrappers, which the walk cannot see through, so it is
    # named directly.
    "python3Packages.numpy" "openblas"
  ],
}:
let
  pkgs = import inputs.nixpkgs-upstream { inherit system; config.allowUnfree = true; };

  keyOf = p: lib.toLower (p.pname or p.name or "unknown");
  isPkg = p: builtins.isAttrs p && (p ? pname || p ? name);
  node = p: { key = keyOf p; pkg = p; };

  seedPkgs = builtins.filter isPkg (
    map (s: let r = builtins.tryEval (lib.attrByPath (lib.splitString "." s) null pkgs); in if r.success then r.value else null) seeds
  );

  closure = builtins.genericClosure {
    startSet = map node seedPkgs;
    operator =
      { pkg, ... }:
      map node (builtins.filter isPkg ((pkg.buildInputs or [ ]) ++ (pkg.propagatedBuildInputs or [ ])));
  };

  linked = builtins.listToAttrs (map (i: { name = i.key; value = true; }) closure);
in
{
  # By top-level attribute name, which is what o3.nix and gentoo-lto.nix hold.
  isBuildToolLinked =
    name:
    let
      r = builtins.tryEval (keyOf (pkgs.${name} or { pname = name; }));
    in
    linked ? ${lib.toLower name} || (r.success && linked ? ${r.value});
  names = builtins.attrNames linked;
}
