{
  description = "NixOS configuration (multi-host)";

  inputs = {
    # Pinned in flake.lock. Use nixos-YY.MM when that branch exists, or keep unstable.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # No public `nixpkgs` flake input — do not wire `follows` (flakes warns otherwise).
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    /* webkitgtk_4_1 only: Emacs xwidgets configure requires webkit2gtk-4.1 < 2.41.92; unstable is newer.
       Do not `follows` nixpkgs — we want an independent lock (currently nixos-22.11 → webkit 2.38.x). */
    nixpkgs-emacs-webkit.url = "github:NixOS/nixpkgs/nixos-22.11";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms-plugin-registry = {
      url = "github:AvengeMedia/dms-plugin-registry";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Doom framework (pinned in flake.lock). Writable bits live in ~/.emacs.d/.local after `doom sync`.
    doom-emacs = {
      url = "github:doomemacs/doomemacs";
      flake = false;
    };

    # Former ~/.doom.d (https://github.com/R0K0R/doom-emacs); pin with flake.lock.
    doom-private = {
      url = "github:R0K0R/doom-emacs";
      flake = false;
    };
  };

  outputs =
    inputs@{ self
    , nixpkgs
    , home-manager
    , ...
    }:
    let
      mkHost =
        hostName:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName; };
          modules = [
            home-manager.nixosModules.home-manager
            ./hosts/${hostName}
          ];
        };
    in
    {
      nixosConfigurations.victus-15 = mkHost "victus-15";
      nixosConfigurations.galaxybook4-pro360 = mkHost "galaxybook4-pro360";
    };
}
