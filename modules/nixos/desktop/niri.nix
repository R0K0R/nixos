{ config, lib, pkgs, ... }:

{
  # Wayland compositor (niri) + graphical login. The niri-flake NixOS module installs
  # niri, registers a display-manager session, polkit, portals, etc.
  config = lib.mkIf (config.wm.compositor == "niri") {
    programs.niri = {
      enable = true;
      package = pkgs.niri-unstable;
    };

    # All packages get meteorlake-specific hashes; niri.cachix.org never hits.
    niri-flake.cache.enable = false;
  };
}
