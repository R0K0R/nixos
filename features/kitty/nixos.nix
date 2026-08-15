{ config, lib, ... }:

{
  options.my.kitty.enable = lib.mkEnableOption "the kitty terminal user config, including the dots-hyprland search kitten";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/kitty/home.nix gates on via osConfig.
  config = lib.mkIf config.my.kitty.enable { };
}
