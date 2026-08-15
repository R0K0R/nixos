{ config, lib, ... }:

{
  options.my.fish.enable = lib.mkEnableOption "the fish shell user config: aliases, abbreviations and interactive init";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/fish/home.nix gates on via osConfig.
  config = lib.mkIf config.my.fish.enable { };
}
