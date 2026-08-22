{ config, inputs, lib, hostName, ... }:

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
        map
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
