{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in

{
  options.my.starship.enable = lib.mkEnableOption "the starship prompt";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/starship/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.starship.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf config.my.starship.enable {
    my.packages.perUser = lib.genAttrs config.my.starship.users (_: pkgSet.user);
  };
}
