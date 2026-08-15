{
  description = "niri compositor, from a locally patched niri-flake";

  /*
    TWO-LEVEL follows, and both halves are required.

    This flake declares its own `nixpkgs` purely so the wrapped input has
    something to follow; the parent then points it at the real fork:

      # root flake.nix
      feat-niri = { url = "path:./features/niri"; inputs.nixpkgs.follows = "nixpkgs"; };

    Miss either half and niri builds against a DIFFERENT nixpkgs -- not a
    cosmetic `nixpkgs_2` lock rename but a genuine second package set, with its
    own glibc and systemd, in the closure. Verified after the fact by comparing
    revs; see the check in the repo README.

    niri-flake-patch lives inside this directory rather than at the repo root so
    the path reference stays local and the feature stays self-contained.
  */
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    niri = {
      # Local copy patched to use nativeBuildInputs in validated-config-for so
      # the niri validate binary is in PATH under strictDeps / pseudo-cross.
      url = "path:./niri-flake-patch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { niri, ... }:
    {
      nixosModule = niri.nixosModules.niri;
      overlay = niri.overlays.niri;
    };
}
