{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in

{
  options.my.fish.enable = lib.mkEnableOption "the fish shell user config: aliases, abbreviations and interactive init";

  # Home-only feature: the NixOS side exists to declare the switch that
  # features/fish/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.fish.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf config.my.fish.enable {
    my.packages.perUser = lib.genAttrs config.my.fish.users (_: pkgSet.user);
  };
}
