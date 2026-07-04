{ pkgs, ... }:

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

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
