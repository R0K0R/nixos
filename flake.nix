{
  description = "NixOS configuration (multi-host)";

  inputs = {
    # Pinned in flake.lock. Use nixos-YY.MM when that branch exists, or keep unstable.
    # combined-fundamental: all cross-build fixes merged onto current
    # nixos-unstable, rebuilt as individual pr/* branches (see nixpkgs-contrib)
    # for upstreaming, plus this one combined branch actually used for building.
    nixpkgs.url = "github:R0K0R/nixpkgs/combined-fundamental";

    # Intentionally NOT follows = "nixpkgs" — unaffected by
    # --override-input nixpkgs path:/home/r0k0r/nixpkgs-patch.
    # Used for nix.nixPath and nix.registry so that nix-shell / nix run
    # evaluate against unpatched nixpkgs and hit the Hydra binary cache.
    nixpkgs-upstream.url = "github:NixOS/nixpkgs/nixos-unstable";

    # No public `nixpkgs` flake input — do not wire `follows` (flakes warns otherwise).
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    /* claude-code binary from Anthropic's release channel, hash-pinned in
       flake.lock. The channel has no version-less "latest" binary URL, so the
       version lives in this URL (and in the package's version attr) -- bump
       both + relock with features/claude-code/update.sh. */
    claude-code-bin = {
      url = "file+https://downloads.claude.ai/claude-code-releases/2.1.223/linux-x64/claude";
      flake = false;
    };

    /* claude-desktop .deb from Anthropic's apt repo (official Linux beta since
       2026-06-30; not in nixpkgs). Same pattern as claude-code-bin: the
       version lives in this URL and the package's version attr -- bump both +
       relock with features/claude-desktop/update.sh. */
    claude-desktop-bin = {
      url = "file+https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_1.24012.11_amd64.deb";
      flake = false;
    };

    /* webkitgtk_4_1 only: Emacs xwidgets configure requires webkit2gtk-4.1 < 2.41.92; unstable is newer.
       Do not `follows` nixpkgs — we want an independent lock (currently nixos-22.11 → webkit 2.38.x). */
    nixpkgs-emacs-webkit.url = "github:NixOS/nixpkgs/nixos-22.11";

    home-manager = {
      # master, not a release branch: nixpkgs here tracks unstable (26.11), and
      # release-26.05's fish module still referenced the pre-fish-4.x
      # share/fish/tools/create_manpage_completions.py path, breaking every
      # *-fish-completions derivation. master is the pairing for nixpkgs unstable.
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    dms = {
      url = "github:AvengeMedia/DankMaterialShell";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The greeter split out of dms itself (see features/dms/nixos.nix).
    dank-greeter = {
      url = "github:AvengeMedia/dank-greeter";
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

    # Former ~/.doom.d (https://github.com/R0K0R/doom-emacs); pin with flake.lock.
    doom-private = {
      url = "github:R0K0R/doom-emacs";
      flake = false;
    };

    # Builds Doom Emacs as real Nix derivations instead of straight.el's
    # imperative git-clone/pull -- see features/emacs/.
    # Its own doomemacs/doomemacs-modules sub-inputs are left un-.follows'd
    # on purpose: ride the framework version it's actually tested against.
    nix-doom-emacs-unstraightened = {
      url = "github:marienz/nix-doom-emacs-unstraightened";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Pinned tag in URL (flake = false inputs do not accept ref/rev attributes).
    samsung-galaxy-book-linux-fixes.url =
      "github:Andycodeman/samsung-galaxy-book-linux-fixes/v0.3.50";
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
      lib = nixpkgs.lib;

      /*
        Feature registration. Every directory under features/ is imported on
        EVERY host, unconditionally; `my.<feature>.enable` decides whether it
        does anything. `imports` is never used as a switch -- that conflation is
        what made modules/nixos/default.nix all-or-nothing and forced headless
        victus-15 to hand-roll duplicates of locale/users/nix-settings.
        A disabled feature costs an option declaration and an unforced mkIf.

        Discovery is a readDir walk, so there is no import list to maintain and
        no way for a feature to be silently left out. The corollary is that a
        file's mere presence activates it: modules/nixos/boot/{kernel,sysrq}.nix
        were dead and broken (one did not even parse) precisely because the old
        hand-written list never referenced them. Nothing may live under
        features/ that is not a real module.
      */
      featureNames = builtins.attrNames (builtins.readDir ./features);
      collect =
        layer:
        {
          imports = builtins.filter builtins.pathExists (
            map (n: ./features + "/${n}/${layer}") featureNames
          );
        };
      nixosFeatures = collect "nixos.nix";
      homeFeatures = collect "home.nix";

      mkHost =
        hostName:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName; };
          modules = [
            home-manager.nixosModules.home-manager
            nixosFeatures
            # Machine-bound tuning backend: march/pseudo-cross platform split,
            # the overlays, and the runtime-cache classifier. Not a feature --
            # it is tied to this nixpkgs fork and to per-host generated data, so
            # it cannot be handed to anyone else the way a feature can.
            ./tuning
            /*
              home-manager integration. Wiring, not a feature, so it lives here
              rather than in a module every host has to remember to import --
              which is exactly what victus-15 used to do, reaching past the
              aggregator for this one file.

              Feature home halves go into sharedModules (rather than a per-user
              config) so one `my.<feature>.enable = true` in the host file drives
              both halves; the home side gates on osConfig.my.*.
            */
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = { inherit inputs hostName; };
                backupFileExtension = "hm-backup";
                # Allow replacing an existing *.hm-backup when backing up again
                # (avoids an activation crash on the second run).
                overwriteBackup = true;
                sharedModules = [
                  homeFeatures
                  inputs.nix-doom-emacs-unstraightened.homeModule
                ];
                users.r0k0r = import ./home-r0k0r.nix;
              };
            }
            ./hosts/${hostName}
            # Phase-1 bootstrap: pin nixos-rebuild to unpatched upstream so it
            # hits cache.nixos.org and doesn't need to be built from our patched stdenv.
            { system.build.nixos-rebuild = lib.mkForce
                inputs.nixpkgs-upstream.legacyPackages.x86_64-linux.nixos-rebuild; }
          ];
        };
    in
    {
      nixosConfigurations.victus-15 = mkHost "victus-15";
      nixosConfigurations.galaxybook4-pro360 = mkHost "galaxybook4-pro360";

      /*
        Exposed so a feature set can be consumed from outside this repo, and so
        an individual feature stays extractable later without touching any host
        file. mkHost uses the `let` bindings directly rather than these, to keep
        nixosConfigurations from depending on the flake's own output fixpoint.
      */
      nixosModules.default = nixosFeatures;
      homeModules.default = homeFeatures;

      /*
        `nix flake check` as the one-command gate. Forcing each host's toplevel
        is what evaluates its assertions -- including features/_meta's dependency
        checks, which otherwise only fire when someone happens to build.

        Note this triggers nix-doom-emacs-unstraightened's import-from-derivation
        on any change that moves the package set, so run it with a reachable
        builder or `--builders ''`.
      */
      checks.x86_64-linux = lib.mapAttrs (
        _: cfg: cfg.config.system.build.toplevel
      ) self.nixosConfigurations;
    };
}
