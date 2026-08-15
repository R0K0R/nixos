{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.easyeffects.enable = lib.mkEnableOption ''
    the EasyEffects preset collection, installed into the user's config.
    EasyEffects itself is a package, installed separately
  '';

  config = lib.mkIf config.my.easyeffects.enable {
    environment.systemPackages = pkgSet.system;
  };
}
