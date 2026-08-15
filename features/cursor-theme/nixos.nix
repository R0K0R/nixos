{ config, lib, ... }:

{
  options.my.cursor-theme.enable = lib.mkEnableOption "the glass Bibata cursor theme and its XCURSOR environment";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/cursor-theme/home.nix gates on via osConfig.
  config = lib.mkIf config.my.cursor-theme.enable { };
}
