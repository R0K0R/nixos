{ config, inputs, lib, pkgs, ... }:

let
  cfg = config.my.lyre;
  # Prebuilt from lyre's own flake (packages.<system>.default), built against its own
  # nixos-unstable pin -> substitutes from cache. Source: ~/Documents/projects/lyre
  # (the `lyre` path input). Replaces EasyEffects + Timbre: one native PipeWire graph
  # (per-app EQ -> lyre merge -> per-output EQ -> devices), driven over a CLI by the
  # notif-centre Sound menu.
  lyre = inputs.lyre.packages.${pkgs.system}.default;
in
{
  options.my.lyre = {
    enable = lib.mkEnableOption "lyre -- headless PipeWire EQ + routing engine";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ lyre ];
  };
}
