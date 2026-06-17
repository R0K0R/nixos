{ inputs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./home.nix
    ./hardware.nix
    inputs.niri.nixosModules.niri
    ../../modules/nixos
    ../../modules/nixos/nix/remote-builder-client.nix
  ];

  networking.hostName = "victus-15";

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "znver3";
  };

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];
}
