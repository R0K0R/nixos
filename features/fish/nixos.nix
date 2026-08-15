{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in

{
  options.my.fish.enable = lib.mkEnableOption "the fish shell user config: aliases, abbreviations and interactive init";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/fish/home.nix gates on via osConfig.
  config = lib.mkIf config.my.fish.enable {
    users.users.r0k0r.packages = pkgSet.user;
  };
}
