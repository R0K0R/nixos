/*
  sccache for Rust: the cargo counterpart of the ccache'd stdenv in
  tuning/overlays/heavy.nix. Consumed by tuning/overlays/rust-cache.nix (the
  tuned host set) and, unchanged, by the measurement harness; nothing here
  reads module config.

  WHY A FIXED VENDOR PATH. sccache 0.18 keys a rustc call on the command line
  (minus --extern/-L/--check-cfg/--out-dir/--diagnostic-width), the source
  files by content, the extern rlibs by content, CARGO_* env, the env-deps rustc
  reports, the cwd and the compiler. A vendored crate's source path is on that
  command line and is its cwd, and nixpkgs puts the vendor copy at
  /build/<pname>-<version>-vendor -- different for every package. Measured on
  yulee 2026-10-27 (scratchpad probe, fd/ripgrep/zoxide): as nixpkgs builds
  them, a package's own rebuild hit 53/54 and ANY other package 0 (ripgrep
  0/42, zoxide 0/68). With the vendor copy at one path zoxide after fd hit
  12/68 (syn, proc-macro2, unicode-ident, ...). SCCACHE_BASEDIRS would be the
  obvious knob and is C/C++-only in 0.18.

  The move happens in the build, after cargoSetupHook has made the copy, so the
  hook in pkgs/build-support/rust/hooks stays the fork's/upstream's own and the
  Rust platform's hooks keep substituting. A symlink stays at the old name, and
  $cargoDepsCopy is updated, so a package that says either still works.

  WHY THE REMAP IS IN THE WRAPPER, NOT RUSTFLAGS. Two reasons, both cargo's:
  a RUSTFLAGS env var REPLACES every [target.<triple>].rustflags from config
  (cargo takes the first source that is set), which would silently drop the
  -Cforce-frame-pointers=yes the cargo setup hook writes there; and cargo
  folds RUSTFLAGS into every crate's -C metadata, so a per-package value would
  make every crate's command line differ. The wrapper adds it after cargo has
  decided everything, identically for every package, and also when the cache
  is off -- the output must not depend on which builder ran it. Only the
  vendor tree is remapped: workspace crates are already given to rustc as
  relative paths, and their DW_AT_comp_dir is the cwd, which sccache hashes.

  WHAT CAN COME OUT OF THE CACHE. Only rlib and staticlib compiles are cached
  (rust.rs: any other --crate-type is cannot_cache!), so proc-macro, dylib,
  cdylib and bin units -- the final binary included -- are always compiled
  here. Incremental compiles are refused too (-C incremental is cannot_cache!),
  and nixpkgs' release profiles do not enable it. A hit is therefore a
  dependency rlib whose key covers everything that could put a path into it:
  its source path and cwd (fixed /build/cargo-vendor/...), the linker store
  path (-C linker from the cargo setup hook's config), the extern rlibs and
  bundled static archives by content, and every env-dep rustc saw -- so a
  build script's `cargo:rustc-env=X=/nix/store/...` read with env!() is in
  the key, as is OUT_DIR for crates that include!() generated code. -L is NOT
  in the key, but an rlib records native library names, not search paths;
  the link that resolves them is the consuming package's own. The cached rlib
  carries the remapped vendor paths (/cargo-vendor/...) and nothing else of
  the package that produced it.

  Known hole, sccache's not ours (docs/Rust.md): a proc macro that reads files
  without reporting them to rustc. Same-package rebuilds already had it.

  MEASURED, this file on yulee 2026-10-27, nixpkgs-upstream fd, bat,
  hyperfine, zoxide, starship, procs built in that order into one fresh cache
  (hits/misses are sccache's own stats, whole build incl. checkPhase):
    fd 0/68, bat 6/243, hyperfine 14/95, zoxide 33/116, starship 44/312,
    procs 73/193.
  Wall time is NOT better on a first build: zoxide 26.8 s with its 33 hits vs
  25.3 s with no cache, procs 108.4 vs 103.8 s. The hits are small dependency
  crates off the critical path (the big crates and the lto/codegen-units=1
  link never hit), and every miss pays a compressed write. Same-package
  rebuilds (a resume, the other builder, --check) do gain: zoxide 20.4 s
  (116/116), procs 93.0 s (193/193), starship 232.9 s (309/312) against
  305.2 s cold and 295.2 s for upstream's own drv built here. Rebuilding each with no cache under
  `nix-store --check` reproduced the cache-built outputs bit for bit, and their
  references equal upstream's.
*/
{ lib, buildPackages }:

{
  # Root of the builder's cache tree (my.ccache.cacheDir). sccache gets
  # <cacheDir>/sccache for objects and <cacheDir>/sccache.toml for its config.
  cacheDir,
}:

let
  sccache = buildPackages.sccache;
  dir = "${cacheDir}/sccache";
  # The builder's, not ours: dir, size and rw_mode live there (features/nix/
  # ccache writes it on NixOS builders, yulee.md by hand). Missing = no cache.
  # NOT inside `dir` -- sccache's LRU walks every file under its directory and
  # would evict the config like any other entry. And SCCACHE_DIR must NOT be
  # set in the env: it replaces the file's whole [cache.disk] table, size
  # included (config.rs, CacheConfigs::merge).
  conf = "${cacheDir}/sccache.toml";

  # cargo runs "$RUSTC_WRAPPER <rustc> <args...>" for every rustc call,
  # dependencies, build scripts and `rustc -vV` probes alike (the remap is
  # harmless to all of them; checked with rustc 1.98.1).
  wrapper = buildPackages.writeShellScript "rustc-sccache-wrapper" ''
    remap="--remap-path-prefix=''${NIX_BUILD_TOP:-/build}/cargo-vendor=/cargo-vendor"
    if [ -n "''${NIX_SCCACHE_ACTIVE-}" ]; then
      umask 002
      exec ${sccache}/bin/sccache "$@" "$remap"
    fi
    exec "$@" "$remap"
  '';

  hook = buildPackages.makeSetupHook {
    name = "sccache-hook";
    substitutions = {
      sccache = "${sccache}/bin/sccache";
      inherit wrapper dir conf;
    };
    meta.description = "Shared sccache for cargo builds, with a package-independent vendor path";
  } ./sccache-hook.sh;
in
{
  inherit hook dir conf;

  /*
    A rustPlatform whose buildRustPackage adds the hook. Through
    extendMkDerivation so finalAttrs packages, overrideAttrs and the hook's
    own arguments keep working exactly as before.

    buildRustPackage and not cargoSetupHook: the hook a package lists in
    nativeBuildInputs is the SPLICED one, i.e. pkgsBuildHost.rustPlatform's,
    which lives in the build platform and is shared with everything that is
    not tuned. A function is not spliced, so the host set's buildRustPackage
    is the one every host package calls. Packages that use the cargo hooks
    directly (meson + cargo, maturin under buildPythonPackage) are therefore
    not covered; see rust-cache.nix.
  */
  wrapRustPlatform =
    rustPlatform:
    rustPlatform.overrideScope (
      _: super: {
        buildRustPackage = lib.extendMkDerivation {
          constructDrv = super.buildRustPackage;
          extendDrvArgs = _: args: {
            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ hook ];
          };
        };
      }
    );
}
