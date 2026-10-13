{ lib, pkgs, osConfig, inputs, ... }:

let
  bonfire = inputs.bonfire.packages.${pkgs.system}.default;
in
{
  config = lib.mkIf (osConfig.my.bonfire.enable or false) {
    # The engine daemon: long-running (it HOSTS the filter-chain EQ modules -- a chain only
    # lives as long as the client that loaded it -- and reacts to apps/devices over a libpulse
    # event loop, exposing a unix-socket CLI). On start it builds the bonfire null-sink, fans
    # it out to the saved output device(s) through per-output EQ, makes it the default, and
    # routes EQ'd apps through their per-app EQ -- so audio works on boot. If it dies,
    # WirePlumber still picks a real device as default (always a working fallback).
    systemd.user.services.bonfire = {
      Unit = {
        Description = "bonfire -- PipeWire per-app/per-output EQ + routing engine";
        After = [ "pipewire.service" "pipewire-pulse.service" "wireplumber.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
      Service = {
        ExecStart = "${bonfire}/bin/bonfire daemon";
        Restart = "on-failure";
        RestartSec = 2;
        Slice = "session.slice";
      };
    };
  };
}
