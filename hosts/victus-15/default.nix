{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./home.nix
    inputs.niri.nixosModules.niri
    ../../modules/nixos
  ];

  networking.hostName = "victus-15";

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];
}
