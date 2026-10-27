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
    #
    # LOCK IT TO THE FORK'S UPSTREAM BASE, not to whatever nixos-unstable is
    # now: tuning/overlays/upstream-tools.nix swaps fork packages for these
    # builds on the premise that both trees are the same revision, and an
    # untuned set (dell-latitude, a home with my.tuning off) is built from it.
    # After rebasing the fork: find its base (the newest non-fork commit of
    # combined-fundamental) and run
    #   nix flake lock --override-input nixpkgs-upstream github:NixOS/nixpkgs/<base>
    # 530051b bumped the fork and left this at e7439b6, three days older; fixed
    # 2026-10-18 (fork 00a171f = upstream 7fd4004d + fork commits).
    nixpkgs-upstream.url = "github:NixOS/nixpkgs/nixos-unstable";

    /*
      Per-feature sub-flakes. Each owns the external inputs only IT consumes, so
      `rm -r features/<name>` takes that feature's whole dependency surface with
      it and the root flake stops carrying pins for things it does not use.
    */
    feat-claude-code.url = "path:./features/apps/claude-code";
    feat-hop.url = "path:./features/apps/hop";
    feat-samsung-galaxybook.url = "path:./features/hardware/samsung-galaxybook";
    feat-hyprland.url = "path:./features/session/hyprland";
    feat-foldpen.url = "path:./features/apps/foldpen";

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

    /*
      The tuning classifier's caches, one directory per host:
      system-tier1.nix / system-tier2.nix (the system's evidence) and
      users/<user>.nix (each user's, written by tuning-refresh). Union-merged by
      tuning/runtime-cache/lookup.nix. In the repo until the admin migrates
      them (scripts/tuning-cache-migrate.sh): then each becomes
      path:/var/lib/tuning-cache/<host>, a plain directory outside the flake,
      locked like any input and relocked by hand (scripts/tuning-cache-relock.sh).
    */
    tuning-cache-galaxybook4-pro360 = {
      url = "path:/var/lib/tuning-cache/galaxybook4-pro360";
      flake = false;
    };
    tuning-cache-victus-15 = {
      url = "path:/var/lib/tuning-cache/victus-15";
      flake = false;
    };
    # Untuned host (my.tuning.enable = false): nothing writes system tier files
    # for it, so its directory holds only the users/ README until a user of
    # that machine tunes a home of their own.
    tuning-cache-dell-latitude = {
      url = "path:./tuning/runtime-cache/hosts/dell-latitude";
      flake = false;
    };

    feat-agenix = {
      url = "path:./features/core/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    feat-impermanence = {
      url = "path:./features/core/impermanence";
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
            # doesn't need to be built from our patched stdenv -- but with THIS
            # host's Nix, as NixOS's own definition does (tools.nix). Upstream's
            # default is 2.34, which lacks 2.35's CA protocol: "the daemon is
            # missing the 'realisation-with-path-not-hash' protocol feature" on
            # every `nixos-rebuild --flake` (2026-10-24). Only the Python
            # wrapper is rebuilt for that; it is small.
            ({ config, ... }: {
              system.build.nixos-rebuild = lib.mkForce
                (inputs.nixpkgs-upstream.legacyPackages.x86_64-linux.nixos-rebuild.override {
                  nix = config.nix.package;
                });
            })
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
                     effective axes per user, and `nix`: what the daemon
                     actually does for each user (daemon access, trust,
                     local/remote builds).
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
                     session-epoch-check, guarded-session and hm-rollback
                     read. mkHome includes it by itself on a host with
                     my.epoch on (through home-manager.sharedModules, see
                     features/core/epoch/epoch-home.nix); exported for a
                     repo that wants it explicitly elsewhere.
      */
      tuningDefaults = {
        march = "system";
        lto = "system";
        o3 = "system";
        packages = { o3 = [ ]; lto = [ ]; };
        exclude = { o3 = [ ]; lto = [ ]; };
      };
      mkHomeLib =
        hostName: nixos:
        let
          gen = import ./lib/home-generator.nix {
            homeModules = [ homeFeatures ];
            inherit inputs hostName;
          };
          t = nixos.config.my.tuning;
          reg = nixos.config.my.registry.loaded;
          hf = reg.hosts.features.${hostName} or { };
          ut = import ./lib/user-tuning.nix { inherit lib mkHostWith tuningRawOf; };
          sc = import ./lib/surface-check.nix { inherit lib; };
          /*
            A home whose set is not the host's must be able to load the
            system's in-process code (docs/multiuser-design.md, "Surface
            compatibility"). Compared against the SAME home on the host's set,
            so mixing the system set already does with itself is not blamed on
            the user. Skipped -- no second evaluation -- for a host-set home.
          */
          /*
            With its own driver tree (my.graphics.driver, features/session/
            gl-namespace) the check turns half around: the system's tree is
            no longer loaded into the home's programs (skip "graphics"; the
            tree's own closure joins the user side instead), and the home's
            tree is loaded into the system's programs run in its sessions --
            checked against the system profile, minus what the system's own
            driver already mixes there.
          */
          surfaceErrors =
            args: cfg:
            if ut.isHostSet cfg.my.tuning hostName nixos then
              [ ]
            else
              let
                base = gen.mkHome ({ inherit nixos; } // args);
                drv = cfg.my.graphics.driver;
                own = drv.enable;
                g = nixos.config.hardware.graphics;
                sysDriver = lib.optionals g.enable ([ g.package ] ++ g.extraPackages);
                forward = sc.check {
                  osConfig = nixos.config;
                  homePackages = cfg.home.packages ++ lib.optionals own (drv.packages ++ drv.packages32);
                  baselinePackages =
                    base.config.home.packages
                    ++ lib.optionals own (base.config.my.graphics.driver.packages ++ base.config.my.graphics.driver.packages32);
                  skip = lib.optional own "graphics";
                };
                reverse = sc.check {
                  osConfig = nixos.config;
                  homePackages = drv.packages;
                  baselinePackages = sysDriver;
                  skip = [ "graphics" "nss" "locale" "pam" ];
                };
                result = forward // {
                  conflicts =
                    forward.conflicts
                    ++ lib.optionals own (map (c: c // { group = "driver"; }) reverse.conflicts);
                };
                mappable = nixos.config.my.gl-namespace.active && lib.elem args.username nixos.config.my.gl-namespace.users;
              in
              lib.optional (result.conflicts != [ ]) (
                sc.explain {
                  who = "homeLib.${hostName}.mkHome ${args.username}";
                  levers = ut.resolve cfg.my.tuning hostName nixos;
                  hostLevers = ut.hostLevers nixos;
                  inherit result;
                  hints =
                    lib.optional (!own && mappable && lib.any (c: c.group == "graphics") result.conflicts)
                      "For the graphics driver: this host can give you your own (my.graphics.driver.enable = true;), built from your set."
                    ++ lib.optional (!(nixos.config.my.users.${args.username}.tuned or true)) ''
                      You are not tuned on ${hostName} (registry/types.nix `tuned`: only admins are), so
                        this home defaults to an untuned set (lib/home-generator.nix). On a march host that
                        is refused until the admins decide the perl/sqlite question
                        (docs/multiuser-design.md, "Open question: perl and sqlite on the march hosts").
                        Nothing for you to change; ask them.'';
                }
              );
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
            # The registry fact (asserted against my.impermanence.enable).
            impermanence = hf.impermanence or false;
            # Whether homes built here record the epoch (and the guard can
            # check them), and the epoch they record.
            epoch = {
              inherit (nixos.config.my.epoch) enable rev;
              value = nixos.config.system.build.epoch;
            };
            # The system's driver and whether a home may bring its own
            # (my.graphics.driver; features/session/gl-namespace).
            graphics = {
              inherit (nixos.config.hardware.graphics) enable enable32Bit;
              packages = map (p: p.pname or (lib.getName p)) (
                lib.optionals nixos.config.hardware.graphics.enable (
                  [ nixos.config.hardware.graphics.package ] ++ nixos.config.hardware.graphics.extraPackages
                )
              );
              perUserDriver = if nixos.config.my.gl-namespace.active then nixos.config.my.gl-namespace.users else [ ];
            };
            # From the registry this host was evaluated with (the same data
            # its accounts came from; a test's extended registry included).
            users = reg.effective.${hostName} or { };
            # The accounts this host's tuning serves (registry/types.nix
            # `tuned`): the others' homes default to an untuned set.
            tunedUsers = reg.tuned.${hostName} or [ ];
            /*
              What the daemon does for each user here -- the honest version
              of the nix and builders axes (lib/registry.nix's header):
              users.<n>.builds.local is false wherever max-jobs = 0, for
              everyone; builds.remote is the daemon's own builders, which
              apply to untrusted users too.
            */
            nix = {
              localBuilds = hf.localBuilds or true;
              remoteBuilds = hf.builderClient or false;
              users = reg.nixFacts.${hostName} or { };
            };
          };
          # The home's own my.tuning picks its package set (lib/user-tuning.nix).
          mkHome =
            args:
            gen.mkHome (
              {
                inherit nixos;
                pkgsFor = t: ut.pkgsFor t hostName nixos;
                extraChecks = surfaceErrors args;
              }
              // args
            );
          # For tests and inspection: the set / the levers a my.tuning value
          # gives on this host (keys as in the home option, all optional).
          pkgsFor = t: ut.pkgsFor (lib.recursiveUpdate tuningDefaults t) hostName nixos;
          tuningFor = t: ut.resolve (lib.recursiveUpdate tuningDefaults t) hostName nixos;
          epoch = nixos.config.system.build.epoch;
          epochModule = import ./features/core/epoch/epoch-home.nix {
            inherit lib;
            epoch = nixos.config.system.build.epoch;
            rev = nixos.config.my.epoch.rev;
          };
        };

      registry = import ./registry { inherit lib; };

      /*
        A host as it will be AFTER a disk migration that has not happened yet,
        to build before the day (docs/impermanence-migration.md). Same module
        list as the real host plus the post-migration file and the registry
        changes the migration commits; the committed host must evaluate to the
        same toplevel.
      */
      migration = { galaxybook4-pro360 = mkHostWith {
        hostName = "galaxybook4-pro360";
        extraModules = [
          ./hosts/galaxybook4-pro360/impermanence.nix
          {
            my.registry.extend =
              raw:
              raw
              // {
                users = raw.users // {
                  r0k0r = raw.users.r0k0r // {
                    overrides = (raw.users.r0k0r.overrides or { }) // { home = "impermanent"; };
                    acceptTypeChange = "admin->admin";
                  };
                };
                hosts = raw.hosts // {
                  features = raw.hosts.features // {
                    galaxybook4-pro360 = raw.hosts.features.galaxybook4-pro360 // { impermanence = true; };
                  };
                };
              };
          }
        ];
      };
      # The LUKS migration (docs/luks-migration.md): the committed host plus
      # the post-migration file, nothing else.
      galaxybook4-pro360-luks = mkHostWith {
        hostName = "galaxybook4-pro360";
        extraModules = [ ./hosts/galaxybook4-pro360/luks.nix ];
      };
      };

      matrix = import ./lib/matrix.nix {
        inherit lib mkHostWith tuningRawOf;
        hosts = [ "galaxybook4-pro360" "victus-15" "dell-latitude" ];
      };
    in
    {
      nixosConfigurations.victus-15 = mkHost "victus-15";
      # Post-migration builds, not hosts (see the binding above).
      inherit migration;
      nixosConfigurations.galaxybook4-pro360 = mkHost "galaxybook4-pro360";
      nixosConfigurations.dell-latitude = mkHost "dell-latitude";

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
        hyprLua { inherit lib; } { name; src; values; } -- a home feature's
        Hyprland Lua fragment, wired into the system's Hyprland home half the
        same way the system's own features do it (lib/hypr-lua.nix). For home
        repos' features (sidedock in r0k0r's).
      */
      lib.hyprLua = import ./lib/hypr-lua.nix;

      /*
        homeFeatures ./features -- a user repo's own feature tree, collected
        exactly as this flake collects its own: features/<category>/<feature>/
        with a home.nix is a feature, the rest are categories, the same
        errors for empty or duplicate directories (lib/feature-dirs.nix), the
        same leaf-name order. A module importing every home.nix found; each
        feature gates itself with my.<feature>.enable.
      */
      lib.homeFeatures =
        root:
        {
          imports = builtins.filter builtins.pathExists (
            map (f: f.path + "/home.nix") (import ./lib/feature-dirs.nix root)
          );
        };

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
      evalTests.user-types = import ./tests/user-types.nix {
        inherit lib mkHostWith mkHomeLib;
      };
      evalTests.user-tuning = import ./tests/user-tuning.nix {
        inherit lib inputs mkHostWith;
        inherit (self) nixosConfigurations homeLib;
      };
      evalTests.impermanence = import ./tests/impermanence.nix {
        inherit lib mkHostWith mkHomeLib;
      };
      evalTests.guest-overlay = import ./tests/guest-overlay.nix {
        inherit lib mkHostWith mkHomeLib;
      };
      evalTests.optional-features = import ./tests/optional-features.nix {
        inherit lib mkHostWith;
      };
      evalTests.class-daemons = import ./tests/class-daemons.nix {
        inherit lib mkHostWith;
      };
      evalTests.gl-namespace = import ./tests/gl-namespace.nix {
        inherit lib mkHostWith mkHomeLib;
        inherit (self) setuidGlChecks;
      };

      /*
        `nix flake check` as the one-command gate. Forcing each host's toplevel
        is what evaluates its assertions -- including features/_meta's dependency
        checks, which otherwise only fire when someone happens to build.

        Note this triggers nix-doom-emacs-unstraightened's import-from-derivation
        on any change that moves the package set, so run it with a reachable
        builder or `--builders ''`.
      */
      checks.x86_64-linux =
        lib.mapAttrs (_: cfg: cfg.config.system.build.toplevel) self.nixosConfigurations
        // lib.mapAttrs' (host: chk: lib.nameValuePair "setuid-no-gl-${host}" chk) (
          lib.filterAttrs (host: _: self.nixosConfigurations.${host}.config.my.gl-namespace.active) self.setuidGlChecks
        )
        // {
          /*
            features/nix/guest-overlay booted: a VM whose /nix is a btrfs
            subvolume, one overlay guest, the design doc's first-run checklist
            as far as a VM without network goes. Plain upstream nixpkgs, never
            the tuned set. Needs kvm (a builder). See tests/guest-overlay-vm.nix.
          */
          guest-overlay-vm = import ./tests/guest-overlay-vm.nix { inherit inputs lib; };
        };

      /*
        Build-time check that no privileged wrapper loads GL (lib/setuid-gl-
        check.nix): a BUILD over the wrappers' runtime closures, so not part
        of any toplevel. For every host, to run on the builders whenever
        wanted (`nix build .#setuidGlChecks.<host>`); under checks only for
        hosts where features/session/gl-namespace is active, where it guards
        something real.
      */
      setuidGlChecks = lib.mapAttrs (
        host: cfg:
        import ./lib/setuid-gl-check.nix {
          inherit lib;
          inherit (cfg) pkgs config;
          hostName = host;
        }
      ) self.nixosConfigurations;
    };
}
