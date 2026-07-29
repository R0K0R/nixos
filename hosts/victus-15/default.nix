{ lib, pkgs, inputs, ... }:

let
  hostRuntimeClassifier = import ../../modules/nixos/nix/host-runtime-classifier.nix {
    inherit inputs;
    system = "x86_64-linux";
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./hardware.nix
    ./power.nix
    ./filesystems.nix
    ./users.nix
    ./locale.nix
    ./services.nix
    ./nix-cache.nix
    ./packages.nix
  ];

  networking.hostName = "victus-15";

  # Ryzen znver3 tuning. buildPlatform is declared WITHOUT gcc.arch so that it
  # differs from hostPlatform, which is what makes this an intra-ISA pseudo-cross
  # build rather than a native one -- same arrangement as galaxybook4-pro360.
  #
  # This is not tuning for its own sake: the split is what upstream-tools-overlay
  # keys off. Natively (host == build) there is only ONE package set, so that
  # overlay's guard falls through and it aliases *everything* to upstream, which
  # would silently delete the znver3/O3/LTO tuning entirely. With the split,
  # pkgsBuildHost is plain x86_64 and byte-identical to upstream (so build tools
  # substitute from cache.nixos.org), while pkgs stays znver3-tuned for anything
  # that actually runs here.
  nixpkgs.buildPlatform = "x86_64-linux";

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "znver3";
  };

  # mkOrder 1600 puts the alias overlay AFTER the default-ordered list below, so
  # the tuning overlays see fork packages and the aliasing happens last. Same
  # layering as galaxybook4-pro360.
  nixpkgs.overlays = lib.mkMerge [
    (lib.mkOrder 1600 [
      (import ../../modules/nixos/nix/upstream-tools-overlay.nix {
        inherit lib inputs;
      })
    ])

    [
      (import ../../modules/nixos/nix/o3-overlay.nix { inherit hostRuntimeClassifier; })
      (import ../../modules/nixos/nix/gentoo-lto-overlay.nix { inherit hostRuntimeClassifier; })
    ]
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
