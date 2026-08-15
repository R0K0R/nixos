{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in

{
  options.my.starship.enable = lib.mkEnableOption "the starship prompt";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/starship/home.nix gates on via osConfig.
  config = lib.mkIf config.my.starship.enable {
    users.users.r0k0r.packages = pkgSet.user;
  };
}
