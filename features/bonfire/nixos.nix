{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.bonfire;
  # Prebuilt from bonfire's own flake (packages.<system>.default), built against its own
  # nixos-unstable pin -> substitutes from cache. Source: ~/Documents/projects/bonfire
  # (the `bonfire` path input). Replaces EasyEffects + Timbre: one native PipeWire graph
  # (per-app EQ -> bonfire merge -> per-output EQ -> devices), driven over a CLI by the
  # notif-centre Sound menu.
  bonfire = inputs.bonfire.packages.${pkgs.system}.default;
in
{
  options.my.bonfire = {
    enable = lib.mkEnableOption "bonfire -- headless PipeWire EQ + routing engine";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ bonfire ];
  };
}
