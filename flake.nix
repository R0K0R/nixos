{
  description = "NixOS configuration (multi-host)";

  inputs = {
    # Pinned in flake.lock. Use nixos-YY.MM when that branch exists, or keep unstable.
    nixpkgs.url = "git+file:///home/r0k0r/nixpkgs-contrib?ref=pseudo-cross-fundamental";

    # Intentionally NOT follows = "nixpkgs" — unaffected by
    # --override-input nixpkgs path:/home/r0k0r/nixpkgs-patch.
    # Used for nix.nixPath and nix.registry so that nix-shell / nix run
    # evaluate against unpatched nixpkgs and hit the Hydra binary cache.
    nixpkgs-upstream.url = "github:NixOS/nixpkgs/nixos-unstable";

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
      # Local copy patched to use nativeBuildInputs in validated-config-for so
      # the niri validate binary is in PATH under strictDeps / pseudo-cross.
      url = "path:./niri-flake-patch";
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

    # Pinned tag in URL (flake = false inputs do not accept ref/rev attributes).
    samsung-galaxy-book-linux-fixes.url =
      "github:Andycodeman/samsung-galaxy-book-linux-fixes/v0.3.34";
    samsung-galaxy-book-linux-fixes.flake = false;

    easyeffects-presets = {
      url = "github:JackHack96/EasyEffects-Presets";
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
      nixosConfigurations.yulee = mkHost "yulee";
    };
}
