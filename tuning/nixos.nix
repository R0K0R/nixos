{ config, inputs, lib, hostName, tuningEnabledRaw, ... }:

let
  cfg = config.my.tuning;

  /*
    Computed once and shared between the o3 and gentoo-lto overlays -- each
    independently importing/recomputing this (a genericClosure walk across ~400
    packages) roughly doubles eval time for no benefit, since both need the
    identical result.
  */
  hostRuntimeClassifier = import ./host-runtime-classifier.nix {
    inherit inputs;
    host = hostName;
    system = "x86_64-linux";
  };
in
{
  options.my.tuning = {
    enable = lib.mkEnableOption ''
      this machine-bound tuning backend, and with it the patched nixpkgs fork.

      OFF (the default) is not merely "no -march". It selects a different
      nixpkgs INPUT for this host -- plain upstream, so the entire package set
      substitutes from cache.nixos.org. Turning march off while staying on the
      fork does NOT achieve that: the fork patches
      pkgs/build-support/cc-wrapper/setup-hook.sh, whose bytes are a build input
      to cc-wrapper, so stdenv's hash moves and every package rebuilds no matter
      what the tuning switches say. Measured: reverting that one file alone
      changes hello.drvPath at plain `import <fork> {}`, with no march, no
      gcc.arch and no overlays. Two more such files (qt-5 and qt-6
      qtbase-setup-hook.sh) do the same for the whole Qt package set.

      Because the choice is an input rather than an option value, it is read out
      of the host file by raw import in flake.nix -- see the note there. It must
      therefore be a LITERAL true/false in hosts/<name>/default.nix: no mkIf, no
      mkMerge, no reference to `config`. The assertion below catches any
      divergence between what flake.nix read and what the module system
      evaluated, so an ignored definition can never pass silently.

      my.tuning.extraOverlays is deliberately NOT gated on this -- it describes
      the machine's hardware, not its toolchain -- and it keeps working on
      upstream nixpkgs because this swaps the input rather than setting
      nixpkgs.pkgs, which would have made overlays silently inert.
    '';

    march = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "meteorlake";
      description = ''
        GCC `-march` for this host's package set, or null for an untuned
        (plain upstream) build.

        Setting it declares buildPlatform WITHOUT gcc.arch so that it differs
        from hostPlatform, which is what makes this an intra-ISA pseudo-cross
        build rather than a native one.

        That split is not tuning for its own sake -- it is what
        overlays/upstream-tools.nix keys off. Natively (host == build) there is
        only ONE package set, so that overlay's guard falls through and it
        aliases *everything* to upstream, silently deleting the arch/O3/LTO
        tuning entirely. With the split, pkgsBuildHost is plain x86_64 and
        byte-identical to upstream (so build tools substitute from
        cache.nixos.org), while pkgs stays tuned for anything that runs here.
      '';
    };

    pseudoCross.enable = lib.mkEnableOption ''
      the generic pseudo-cross and build-load fixes in
      overlays/pseudo-cross.nix -- cross-build configure defects, test suites
      that fail under builder load, and the i686 escape hatch. Wanted by any
      tuned host; nothing in it is specific to one machine
    '';

    o3.enable = lib.mkEnableOption "the -O3 overlay, applied to host-runtime packages only";
    lto.enable = lib.mkEnableOption "the Gentoo-style LTO overlay, applied to host-runtime packages only";

    upstreamTools.enable = lib.mkEnableOption ''
      substituting build-platform tools with byte-identical upstream builds, so
      they come from cache.nixos.org instead of being rebuilt
    '';

    qtPatches.enable = lib.mkEnableOption ''
      pkgs-config.nix: qtbase F16C/mysql patching and the yulee-sandbox test
      exclusions. Meteorlake-specific -- a differently-tuned host wants its own
    '';

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/r0k0r/flakes/nixos";
      description = "Where this flake lives on disk, baked into runtime-cache-refresh.";
    };

    extraOverlays = lib.mkOption {
      type = lib.types.listOf (lib.types.functionTo (lib.types.functionTo lib.types.attrs));
      default = [ ];
      description = ''
        Host-specific overlays: this machine's GPU, its fingerprint sensor, a
        compositor package set. Anything that is about the hardware rather than
        about the toolchain, and so cannot be shared.
      '';
    };
  };

  imports = [
    ./pkgs-config.nix
    ./runtime-cache-refresh.nix
  ];

  config = lib.mkMerge [
    /*
      extraOverlays applies UNCONDITIONALLY -- it is not tuning.

      It used to sit inside the march gate, which meant `march = null` also
      silently dropped this host's GPU driver trim and its niri package set:
      overlays that describe the machine's hardware and have nothing to do
      with the toolchain, exactly as this option's own description says. The
      niri one is the sharp edge -- it would vanish with no error and only
      surface later as a missing compositor.
    */
    { nixpkgs.overlays = cfg.extraOverlays; }

    /*
      Everything from here to the assertions is the tuning backend proper, and
      exists only when this host opted in. With `enable = false` flake.nix has
      already handed the host plain upstream nixpkgs, so leaving any of it
      active would tune a package set that is meant to substitute wholesale.

      The assertions stay OUTSIDE this gate on purpose: `march = "meteorlake"`
      next to `enable = false` must produce an error naming the missing line,
      not a silently untuned machine that still looks configured.
    */
    (lib.mkIf cfg.enable (lib.mkMerge [

    /*
      march itself: the buildPlatform/hostPlatform split, and nothing else.
      Every tuning overlay below is now gated on its OWN switch rather than
      riding along with this one.
    */
    (lib.mkIf (cfg.march != null) {
      nixpkgs.buildPlatform = "x86_64-linux";

      nixpkgs.hostPlatform = lib.systems.elaborate {
        system = "x86_64-linux";
        gcc.arch = cfg.march;
      };
    })

    /*
      Overlay ORDER is preserved exactly as it was when these shared one list:
      o3, lto, then the pseudo-cross pair, then extraOverlays at the default
      priority -- mkMerge concatenates same-priority definitions in the order
      written -- and upstream-tools last at mkOrder 1600, so it sees fork
      packages and aliases last.

      (extraOverlays is defined above rather than here purely so its comment
      can stand alone; same priority, and it is written after these, so it
      still lands after them. If that ever stops being true, upstream-tools'
      1600 is the only ordering that actually matters to correctness.)
    */
    (lib.mkIf cfg.o3.enable {
      nixpkgs.overlays = [ (import ./overlays/o3.nix { inherit hostRuntimeClassifier; }) ];
    })

    (lib.mkIf cfg.lto.enable {
      nixpkgs.overlays = [ (import ./overlays/gentoo-lto.nix { inherit hostRuntimeClassifier; }) ];
    })

    (lib.mkIf cfg.pseudoCross.enable {
      nixpkgs.overlays =
        [ (import ./overlays/perl-tk-stub.nix) ]
        ++ import ./overlays/pseudo-cross.nix { inherit lib inputs; };
    })

    (lib.mkIf cfg.upstreamTools.enable {
      nixpkgs.overlays = lib.mkOrder 1600 [
        (import ./overlays/upstream-tools.nix { inherit lib inputs hostRuntimeClassifier; })
      ];
    })

    ]))

    /*
      The one thing that cannot be expressed as an ordinary dependency: whether
      flake.nix's raw read of this option agrees with what the module system
      actually evaluated.

      They diverge if my.tuning.enable is ever set from somewhere the raw import
      cannot see -- another module, a property list, an mkForce in a profile. The
      failure that produces is the worst available: flake.nix picks upstream
      nixpkgs while every module here behaves as though the fork were in place
      (or the reverse), and nothing else in the system would notice. Comparing
      the two is the only place that mismatch is visible.
    */
    {
      assertions = [
        {
          assertion = cfg.enable == tuningEnabledRaw;
          message = ''
            my.tuning.enable evaluated to ${lib.boolToString cfg.enable}, but flake.nix
            read ${lib.boolToString tuningEnabledRaw} from hosts/${hostName}/default.nix,
            and has already selected the ${
              if tuningEnabledRaw then "patched fork" else "plain upstream"
            } nixpkgs on that basis.

            Set my.tuning.enable as a literal in hosts/${hostName}/default.nix. It cannot
            be defined from another module or wrapped in mkIf/mkMerge: the nixpkgs input
            is chosen before the module system exists.
          '';
        }
      ];
    }

    /*
      Separating the switches makes it possible to enable a tuning overlay
      WITHOUT march, which would not error -- it would do nothing at all.
      Both o3.nix and gentoo-lto.nix skip unless
      `stdenv.hostPlatform.gcc.arch` is non-empty (their platform guard, which
      exists so tuning never touches pkgsBuildHost and cost the ~91% of the
      closure that substitutes from cache.nixos.org). With march unset NO
      package set carries gcc.arch, so the guard skips everything.

      upstream-tools is worse than inert without the split: its host/build
      discrimination collapses, and it aliases EVERYTHING to upstream --
      silently deleting whatever tuning is enabled. That is the failure the
      march option's own description warns about.

      So: assert, never auto-enable, per features/_meta's rule. The message
      names the exact line to add.
    */
    {
      assertions =
        /*
          Everything here hangs off `enable`, because with it off the host is on
          plain upstream nixpkgs and none of these can do what they claim.
          march is called out separately from the overlays: it is the one that
          silently produces a WORKING but fully-rebuilt system (a pseudo-cross
          split against an unpatched tree), which is the outcome hardest to
          notice and most expensive to sit through.
        */
        [
          {
            assertion = cfg.march == null || cfg.enable;
            message =
              "my.tuning.march is set to ${toString cfg.march} but my.tuning.enable is false. "
              + "flake.nix has given this host plain upstream nixpkgs, so the pseudo-cross "
              + "split would rebuild the entire package set against an unpatched tree instead "
              + "of substituting it from cache.nixos.org. Add my.tuning.enable = true;";
          }
          {
            assertion = !cfg.qtPatches.enable || cfg.enable;
            message =
              "my.tuning.qtPatches.enable requires my.tuning.enable (its overlays and "
              + "nixpkgs.config entries only make sense against the patched fork)";
          }
        ]
        ++ map
          (o: {
            assertion = !o.enabled || cfg.march != null;
            message = "my.tuning.${o.name}.enable requires my.tuning.march to be set (it is null; ${o.why})";
          })
          [
            {
              name = "o3";
              enabled = cfg.o3.enable;
              why = "o3.nix skips every package when hostPlatform.gcc.arch is empty";
            }
            {
              name = "lto";
              enabled = cfg.lto.enable;
              why = "gentoo-lto.nix skips every package when hostPlatform.gcc.arch is empty";
            }
            {
              name = "upstreamTools";
              enabled = cfg.upstreamTools.enable;
              why = "without the split it aliases everything to upstream, deleting all tuning";
            }
            {
              name = "pseudoCross";
              enabled = cfg.pseudoCross.enable;
              why = "its fixes only apply to cross builds, and there is no split without march";
            }
          ];
    }
  ];
}
