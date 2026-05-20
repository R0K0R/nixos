{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./home.nix
    inputs.niri.nixosModules.niri
    ../../modules/nixos
  ];

  networking.hostName = "galaxybook4-pro360";

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];

  hardware.graphics.enable = true;
}
