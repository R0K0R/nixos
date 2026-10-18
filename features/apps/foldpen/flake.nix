{
  description = "foldpen -- Galaxy Z Fold 6 as a stylus tablet for Hyprland (pin only)";

  /*
    The code lives in its own repo (~/git_shit/foldpen): the Android app, the
    daemon and a NixOS module. This flake only pins it.

    NO nixpkgs follows, deliberately. The module builds the daemon with the
    HOST's pkgs; the only thing taken from foldpen's own nixpkgs is the APK,
    a build artifact of two plain files with no runtime references, built
    there because the Android SDK substitutes from cache.nixos.org and
    following the fork would build it against the tuned set for nothing.

    git+file reads COMMITTED files only: commit in ~/git_shit/foldpen, then
    `nix flake update foldpen --flake ./features/foldpen` and
    `nix flake update feat-foldpen`.
  */
  inputs.foldpen.url = "git+file:///home/r0k0r/git_shit/foldpen";

  outputs = { foldpen, ... }: {
    nixosModule = foldpen.nixosModules.default;
  };
}
