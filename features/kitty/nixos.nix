{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in

{
  options.my.kitty.enable = lib.mkEnableOption "the kitty terminal user config, including the dots-hyprland search kitten";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/kitty/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.kitty.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf config.my.kitty.enable {
    my.packages.perUser = lib.genAttrs config.my.kitty.users (_: pkgSet.user);
  };
}
