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

    /*
      Per-feature sub-flakes. Each owns the external inputs only IT consumes, so
      `rm -r features/<name>` takes that feature's whole dependency surface with
      it and the root flake stops carrying pins for things it does not use.
    */
    feat-claude-code.url = "path:./features/apps/claude-code";
    feat-hop.url = "path:./features/apps/hop";
    feat-claude-desktop.url = "path:./features/apps/claude-desktop";
    feat-claude-science.url = "path:./features/apps/claude-science";
    feat-samsung-galaxybook.url = "path:./features/hardware/samsung-galaxybook";
    feat-easyeffects.url = "path:./features/apps/easyeffects";
    feat-hyprland.url = "path:./features/session/hyprland";

    # Module/overlay-providing sub-flakes need the second half of the two-level
    # follows -- see each sub-flake's own header for why both are required.
    feat-niri = {
      url = "path:./features/session/niri";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-dms = {
      url = "path:./features/session/dms";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-hakuspace = {
      url = "path:./features/session/hakuspace";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-agenix = {
      url = "path:./features/core/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-emacs = {
      url = "path:./features/apps/emacs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      # master, not a release branch: nixpkgs here tracks unstable (26.11), and
      # release-26.05's fish module still referenced the pre-fish-4.x
      # share/fish/tools/create_manpage_completions.py path, breaking every
      # *-fish-completions derivation. master is the pairing for nixpkgs unstable.
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
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

        The walk is recursive (lib/feature-dirs.nix): a directory without
        nixos.nix/home.nix is a category, so features can be grouped as
        features/<category>/<feature>/. Same walk as tuning's Tier 3 anchors.
      */
      featureDirs = import ./lib/feature-dirs.nix ./features;
      collect =
        layer:
        {
          imports = builtins.filter builtins.pathExists (
            map (f: f.path + "/${layer}") featureDirs
          );
        };
      nixosFeatures = collect "nixos.nix";
      homeFeatures = collect "home.nix";

      /*
        WHICH NIXPKGS A HOST GETS, decided before the module system exists.

        `my.tuning.enable = false` -- or `march = null`, see forkWanted below --
        hands a host plain upstream nixpkgs so its whole package set
        substitutes from cache.nixos.org. That cannot be an
        ordinary option read from `config`: the input has to be chosen to build
        the fixpoint that `config` lives in. So the literals are read out of the
        host file by RAW IMPORT -- the same technique
        tuning/runtime-cache/lookup.nix:185 uses for my.packages.extra, with the
        same constraint and the same _type rejection, because there is no module
        evaluation here that could resolve a property list.

        WHY NOT nixpkgs.pkgs, the option that exists for exactly this: the
        nixpkgs module asserts `nixpkgs.pkgs is defined -> nixpkgs.config == {}`
        (nixos/modules/misc/nixpkgs.nix:409, unconditional). This config sets
        nixpkgs.config in two places that have nothing to do with tuning --
        features/nix-settings (allowUnfree) and features/emacs (problems.handlers)
        -- so that route needs `nixpkgs.config = mkForce {}` plus a hand-copy of
        those values into the import, where the next key anyone adds is silently
        dropped. It also makes nixpkgs.overlays silently ignored, which would
        quietly delete my.tuning.extraOverlays -- this host's GPU trim and
        fingerprint fork. Swapping the input keeps config and overlays working
        normally.

        SAFE because the fork patches only pkgs/ (71 files; nothing under nixos/
        or lib/, verified by tree diff), so `np.lib.nixosSystem` and the whole
        NixOS module tree are byte-identical either way. This swaps the package
        set, not the module system.
      */
      tuningRawOf =
        hostName:
        let
          raw = import (./hosts + "/${hostName}") {
            inherit inputs lib hostName;
            pkgs = throw "flake.nix: hosts/${hostName} -- my.tuning.{enable,march} must not read `pkgs`";
            config = throw "flake.nix: hosts/${hostName} -- my.tuning.{enable,march} must not read `config`";
          };
          t = raw.my.tuning or { };
          enable = t.enable or false;
          march = t.march or null;
          wrapped =
            name: v: expect:
            throw ''
              flake.nix: hosts/${hostName}/default.nix wraps my.tuning.${name} in ${
                v._type or builtins.typeOf v
              }.
              It must be a literal ${expect}. The nixpkgs input is chosen before the
              module system exists, so nothing here can resolve mkIf/mkMerge.'';
        in
        {
          enable = if builtins.isBool enable then enable else wrapped "enable" enable "`true` or `false`";
          march =
            if march == null || builtins.isString march then
              march
            else
              wrapped "march" march "string or null";
        };

      /*
        THE FORK ONLY WHERE A LEVER NEEDS IT, and the one that does is march.

        What the fork is for: the IntraISACross split (buildPlatform without
        gcc.arch, hostPlatform with it) and the ~63 pr/* fixes that make that
        split build. Its cc-wrapper/setup-hook.sh patch -- the one whose bytes
        move stdenv's hash and rebuild everything -- only acts under
        NIX_IS_INTRA_ISA_CROSS, i.e. only with march. intraISACross,
        upstreamTools and qtPatches reach the fork only THROUGH march: each
        asserts it (tuning/nixos.nix), being fixes for the split or for the
        fork's meteorlake qtbase. o3 and lto do not need it at all: without
        march they run natively on upstream (tuning/overlays/native-target.nix).

        So `enable = true` with `march = null` used to buy a full rebuild on the
        fork with no tuning in it at all -- the trap the enable option's
        description warns about. It now gets upstream nixpkgs and substitutes;
        o3/lto (native mode) and heavy/refreshTool, which do not depend on the
        fork, still apply (CA is its own feature now, features/nix/ca-derivations).
        Both hosts set march, so nothing about them moves.
      */
      forkWanted = r: r.enable && r.march != null;

      /*
        mkHostWith exists for lib.matrix (lib/matrix.nix): a synthetic variant
        supplies its own tuningRaw and an extra module. A real host passes
        neither, so its module list is exactly what it was.
      */
      mkHost = hostName: mkHostWith { inherit hostName; };
      mkHostWith =
        { hostName, tuningRaw ? tuningRawOf hostName, extraModules ? [ ] }:
        let
          tuningEnabledRaw = tuningRaw.enable;
          tuningMarchRaw = tuningRaw.march;
          np = if forkWanted tuningRaw then nixpkgs else inputs.nixpkgs-upstream;
        in
        np.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit inputs hostName tuningEnabledRaw tuningMarchRaw; };
          modules = [
            home-manager.nixosModules.home-manager
            nixosFeatures
            # Machine-bound tuning backend: march/IntraISACross platform split,
            # the overlays, and the runtime-cache classifier. Not a feature --
            # it is tied to this nixpkgs fork and to per-host generated data, so
            # it cannot be handed to anyone else the way a feature can.
            ./tuning
            # home-manager wiring, shared with tier2-eval so the classifier sees
            # the same home packages this host does. See lib/home-manager.nix.
            # my.users from registry/ -- people are flake-level data, a host
            # only lists who lives on it. See lib/registry.nix.
            ./lib/registry-users.nix
            (import ./lib/home-manager.nix {
              homeModules = [ homeFeatures ];
              inherit inputs hostName;
            })
            ./hosts/${hostName}
            # Phase-1 bootstrap: pin nixos-rebuild to unpatched upstream so it
            # hits cache.nixos.org and doesn't need to be built from our patched stdenv.
            { system.build.nixos-rebuild = lib.mkForce
                inputs.nixpkgs-upstream.legacyPackages.x86_64-linux.nixos-rebuild; }
          ] ++ extraModules;
        };

      /*
        What a user's standalone home repo gets from this flake, per host.

          pkgs       the host's own package set (tuned, IntraISACross) --
                     config's pkgs, so a home built against it reuses the
                     system's store paths instead of rebuilding them.
          osConfig   the host's NixOS config. TRANSITIONAL: the feature home
                     halves still read osConfig.my.* to decide what to do,
                     and this shim lets them run unchanged outside NixOS.
                     The intent is for `facts` to replace it.
          modules    the collected feature home halves + Unstraightened's
                     module, i.e. the generator's sharedModules.
          facts      plain data: host, system, tuning levers, the registry's
                     effective axes per user.
          mkHome     { username, modules ? [ ], asSubmodule ? true } -> a
                     home-manager configuration (has .activationPackage),
                     built by the SAME generator as the integrated
                     home-manager.users.<name>. See lib/home-generator.nix
                     for asSubmodule and why HM's homeManagerConfiguration
                     cannot be used on these hosts.
          epoch      this revision's system epoch (features/core/epoch,
                     lib/epoch.nix) -- what a home built from this homeLib
                     was built against.
          epochModule  home module writing that epoch (and the rev) into
                     every generation as `$generation/epoch`, which
                     session-epoch-check and hm-rollback read. NOT in
                     `modules`: adding a file to the generation changes the
                     activation package, so including it by default would
                     move every existing home. A user repo opts in with
                     modules = [ ... system.homeLib.<host>.epochModule ].
      */
      mkHomeLib =
        hostName: nixos:
        let
          gen = import ./lib/home-generator.nix {
            homeModules = [ homeFeatures ];
            inherit inputs hostName;
          };
          t = nixos.config.my.tuning;
        in
        {
          inherit (nixos) pkgs;
          osConfig = nixos.config;
          modules = gen.sharedModules;
          facts = {
            inherit hostName;
            system = nixos.pkgs.stdenv.hostPlatform.system;
            tuning = {
              inherit (t) enable march;
              lto = t.lto.enable;
              o3 = t.o3.enable;
              intraISACross = t.intraISACross.enable;
            };
            impermanence = false;
            users = registry.effective.${hostName} or { };
          };
          mkHome = args: gen.mkHome ({ inherit nixos; } // args);
          epoch = nixos.config.system.build.epoch;
          epochModule = import ./features/core/epoch/epoch-home.nix {
            inherit lib;
            epoch = nixos.config.system.build.epoch;
            rev = nixos.config.my.epoch.rev;
          };
        };

      registry = import ./registry { inherit lib; };

      matrix = import ./lib/matrix.nix {
        inherit lib mkHostWith tuningRawOf;
        hosts = [ "galaxybook4-pro360" "victus-15" ];
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

      /*
        The user registry, validated: users, types, hosts, and `effective`
        (host -> user -> axes). `nix eval .#registry.effective` is the quickest
        way to see what a type change would mean before any host evaluates.
      */
      inherit registry;

      homeLib = lib.mapAttrs mkHomeLib self.nixosConfigurations;

      /*
        homeConfigurationFor "<host>" { username = "r0k0r"; modules = [ ... ]; }
        -- the same as homeLib.<host>.mkHome, for a user repo that wants one
        call per homeConfigurations entry.
      */
      lib.homeConfigurationFor = host: args: self.homeLib.${host}.mkHome args;

      /*
        The evaluation matrix: lib.matrix.<host>.<variant> is a full
        nixosSystem with optional levers toggled (off, march, lto, o3, lto-o3,
        march-lto, march-o3, ccache, ca, all). See lib/matrix.nix for what
        each variant forces and why emacs is off in it; scripts/eval-matrix.sh
        runs the lot with builds disabled.

        Under lib, NOT checks: `nix flake check` builds checks, and a variant
        on plain upstream nixpkgs is a whole different system to fetch or
        build. These are for evaluating, never for building.
      */
      lib.matrix = matrix.matrix;
      lib.matrixWithEmacs = matrix.matrixWithEmacs;
      lib.matrixInfo = matrix.matrixInfo;

      /*
        `nix flake init -t <this flake>#home`: a user's home repo, consuming
        homeLib. Outputs only -- nothing here evaluates on any host.
      */
      templates.home = {
        path = ./templates/home;
        description = "Standalone home-manager repo on top of this system flake's homeLib";
      };
      homeModules.default = homeFeatures;

      /*
        Evaluation-only tests: NOT under checks, because `nix flake check`
        builds checks. Force them with builds disabled, as
        tests/session-safety-eval.sh does, so an unbuilt IFD fails instead of
        building. Each is a synthetic copy of a real host (mkHostWith), never
        the host itself.
      */
      evalTests.session-safety = import ./tests/session-safety.nix {
        inherit lib;
        mkHostWith = mkHostWith;
        mkHomeLib = mkHomeLib;
      };

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
