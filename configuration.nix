# Edit this configuration file to define what should be installed on your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ inputs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    inputs.niri.nixosModules.niri
    ./modules/nixos
  ];

  nixpkgs.overlays = [ inputs.niri.overlays.niri ];
}
