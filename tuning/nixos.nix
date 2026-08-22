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
      nixpkgs INPUT for this host -- plain upstream -- so the entire package set
      substitutes from cache.nixos.org and nothing is compiled locally beyond
      the few hundred config-generated derivations every NixOS system builds.
      This is what you want on a machine that is not doing toolchain work.

      Turning march off while staying on the fork does NOT achieve that: the
      fork patches pkgs/build-support/cc-wrapper/setup-hook.sh, whose bytes are
      a build input to cc-wrapper, so stdenv's hash moves and every package
      rebuilds no matter what the tuning switches say.

      Because the choice is an INPUT rather than an option value, it is read out
      of the host file by raw import in flake.nix -- see the note there. It must
      therefore be a LITERAL true/false in hosts/<name>/default.nix: no mkIf, no
      mkMerge, no reference to `config`. The assertion below compares what
      flake.nix read against what the module system evaluated, so a definition
      that flake.nix could not see can never pass silently.
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
    Assertions live OUTSIDE the gate below: `march = "meteorlake"` next to
    `enable = false` must produce an error naming the missing line, not a
    silently untuned machine that still reads as configured.
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
          be defined from another module or wrapped in mkIf/mkMerge: the nixpkgs input is
          chosen before the module system exists.
        '';
      }
      {
        assertion = cfg.march == null || cfg.enable;
        message =
          "my.tuning.march is set to ${toString cfg.march} but my.tuning.enable is false. "
          + "flake.nix has given this host plain upstream nixpkgs, so the pseudo-cross split "
          + "would rebuild the entire package set against an unpatched tree instead of "
          + "substituting it from cache.nixos.org. Add my.tuning.enable = true;";
      }
    ];
  }

  (lib.mkIf (cfg.enable && cfg.march != null) {
    nixpkgs.buildPlatform = "x86_64-linux";

    nixpkgs.hostPlatform = lib.systems.elaborate {
      system = "x86_64-linux";
      gcc.arch = cfg.march;
    };

    nixpkgs.overlays = lib.mkMerge [
      /*
        mkOrder 1600 puts the alias overlay AFTER the default-ordered list
        below, so the tuning overlays see fork packages and the aliasing happens
        last.
      */
      (lib.mkOrder 1600 (
        lib.optional cfg.upstreamTools.enable (import ./overlays/upstream-tools.nix {
          inherit lib inputs hostRuntimeClassifier;
        })
      ))

      (
        lib.optional cfg.o3.enable (import ./overlays/o3.nix { inherit hostRuntimeClassifier; })
        ++ lib.optional cfg.lto.enable (import ./overlays/gentoo-lto.nix { inherit hostRuntimeClassifier; })
        ++ lib.optionals cfg.pseudoCross.enable (
          [ (import ./overlays/perl-tk-stub.nix) ]
          ++ import ./overlays/pseudo-cross.nix { inherit lib inputs; }
        )
        ++ cfg.extraOverlays
      )
    ];
  })
  ];
}
