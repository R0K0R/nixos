{ config, lib, ... }:

{
  options.my.starship.enable = lib.mkEnableOption "the starship prompt";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/starship/home.nix gates on via osConfig.
  config = lib.mkIf config.my.starship.enable { };
}
