{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./home.nix
    inputs.niri.nixosModules.niri
    ../../modules/nixos/hardware/victus-15.nix
    ../../modules/nixos
  ];

  networking.hostName = "victus-15";

  custom.waydroid.enable = true;

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];
}
