{
  description = "Doom Emacs, built as real Nix derivations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    /*
      Builds Doom as real Nix derivations instead of straight.el's imperative
      git-clone/pull. Its own doomemacs/doomemacs-modules sub-inputs are left
      un-`follows`'d on purpose: ride the framework version it is actually
      tested against, rather than hand-managing version skew -- the exact bug
      class this replaced.
    */
    nix-doom-emacs-unstraightened = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Former ~/.doom.d (https://github.com/R0K0R/doom-emacs).
    doom-private = {
      url = "github:R0K0R/doom-emacs";
      flake = false;
    };
  };

  outputs =
    { nix-doom-emacs-unstraightened, doom-private, ... }:
    {
      homeModule = nix-doom-emacs-unstraightened.homeModule;
      doomDir = doom-private;
    };
}
