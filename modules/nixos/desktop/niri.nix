{ pkgs, ... }:

{
  # Wayland compositor (niri) + graphical login. The niri-flake NixOS module installs
  # niri, registers a display-manager session, polkit, portals, etc.
  programs.niri = {
    enable = true;
    package = pkgs.niri-unstable;
  };
}
