{
  description = "HOP (Open HWP) -- HWP/HWPX document editor, built from source against a patched rhwp";

  /*
    No nixpkgs input: this flake owns pins and nothing more, so there is no
    second package set and no two-level `follows` to get wrong. Same shape as
    features/claude-desktop/flake.nix -- see its header.
  */
  inputs = {
    # HOP itself, at the tag whose .deb this used to repackage.
    hop-src = {
      url = "github:golbin/hop/v0.4.1";
      flake = false;
    };

    /*
      rhwp, from OUR FORK rather than edwardkim/rhwp.

      HOP consumes rhwp as a git submodule: apps/studio-host builds
      third_party/rhwp/rhwp-studio/src (vite alias `@`), and the Tauri crate
      takes it as a cargo path dependency. The fork carries two font-caching
      commits on top of upstream v0.7.19 -- see the branch for the measurements.

      WHY THIS FORCES A SOURCE BUILD, and why the old .deb repack cannot work
      any more: the fix is TypeScript compiled into the studio bundle, and a
      HOP release embeds that bundle INSIDE the binary. The installed package is
      eight files -- one ELF plus a .desktop, a mime XML and four icons -- with
      no .js, .html or .wasm to patch. Nothing short of rebuilding produces a
      HOP that contains it.

      The vendored rhwp_bg.wasm is used as shipped. The patches are pure
      TypeScript, so wasm-pack is NOT needed in this build.
    */
    rhwp-src = {
      url = "github:R0K0R/rhwp/perf/font-substitution-caches";
      flake = false;
    };
  };

  outputs =
    { hop-src, rhwp-src, ... }:
    {
      src = hop-src;
      rhwp = rhwp-src;

      /*
        READ FROM THE SOURCE, never written down here.

        The old .deb pin had to state the version twice -- once inside the
        release URL and once as an attr -- so features/hop/update.sh existed
        mainly to sed both in lockstep and keep them from drifting. A git input
        carries package.json, so there is nothing to keep in sync: bump the tag
        and the version follows by construction.

        This is a plain file read of a flake input, not import-from-derivation:
        the source is already realised when the flake is evaluated.
      */
      version = (builtins.fromJSON (builtins.readFile "${hop-src}/package.json")).version;
    };
}
