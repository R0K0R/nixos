{ config, lib, pkgs, ... }:

let
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.easyeffects.enable = lib.mkEnableOption ''
    EasyEffects and the JackHack96 preset collection, translated into the
    layout the app actually reads (output/ for presets, irs/ for the impulse
    responses they reference)
  '';

  options.my.easyeffects.startUp = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Start EasyEffects hidden at login, so its effects are applied without
      opening the window. Same idea as my.samsung-ecosystem.budsStartUp.

      The unit is declared on the home-manager side rather than as a NixOS
      systemd.user.service, which is where the buds client puts it: a NixOS
      user service is generated for EVERY account on the machine, so it would
      start EasyEffects for people this feature was never scoped to.
      home-manager units are per-user, so it follows my.easyeffects.users.

      Off by default -- it is a persistent audio filter graph, and turning it on
      silently would change how the machine sounds.
    '';
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.easyeffects.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf config.my.easyeffects.enable {
    environment.systemPackages = pkgSet.system;
  };
}
