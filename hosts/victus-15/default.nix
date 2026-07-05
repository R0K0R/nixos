{ lib, pkgs, ... }:

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
    ./home.nix
  ];

  networking.hostName = "victus-15";

  # Ryzen znver3 tuning, built natively on the machine itself (not cross-compiled),
  # so none of the pseudo-cross machinery applies here — same tradeoff
  # galaxybook4-pro360 already accepts: no cache.nixos.org hits, builds from source.
  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "znver3";
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
