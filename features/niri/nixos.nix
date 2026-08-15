{ config, inputs, lib, pkgs, ... }:

{
  /*
    The niri-flake NixOS module installs niri, registers a display-manager
    session, polkit, portals, etc -- and declares the `niri-flake` and
    `programs.niri` options this feature writes to. Imported here rather than
    from a host file: `imports` cannot be gated, so a feature that writes an
    option must be the thing that brings that option into existence, or it
    breaks on every host that does not happen to import the module itself.
  */
  imports = [ inputs.feat-niri.nixosModule ];

  # Wayland compositor (niri) + graphical login.
  config = lib.mkIf (config.my.desktop.compositor == "niri") {
    programs.niri = {
      enable = true;
      package = pkgs.niri-unstable;
    };

    # All packages get meteorlake-specific hashes; niri.cachix.org never hits.
    niri-flake.cache.enable = false;
  };
}
