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

  imports = [ ./pkgs-config.nix ];

  config = lib.mkIf (cfg.march != null) {
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
  };
}
