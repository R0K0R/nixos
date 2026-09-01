{ pkgs, lib, osConfig, ... }:

let
  /*
    wvkbd upstream has no way to make the panel narrower than the full
    output width: the layer-shell anchor (BOTTOM | LEFT | RIGHT) is a
    compile-time constant with no CLI flag, so "not full width" is only
    reachable by patching. Also swaps the Compose key for Super on both
    default primary layers (portrait "Full" and landscape "Landscape" --
    wvkbd picks between them by aspect ratio, see the layout.mobintl.h edit
    below) -- Super otherwise only exists on the "Special" layer, reachable
    via the next-layer button, not on either primary typing layer.

    Both edits are pinned to exact upstream line numbers rather than
    context blocks: the surrounding code (esp. the Compose key line) is
    byte-identical across several other layers in the same file, so a
    context-matched substitution would silently touch the wrong layer.
    Fine for a single pinned nixpkgs revision; will need re-checking if
    wvkbd is ever bumped.
  */
in

lib.mkIf osConfig.my.dms.enable {

  programs.dank-material-shell.plugins = {
    oskToggle = {
      enable = false;
      src = ./plugins/osk-toggle;
    };

    screenshot = {
      enable = true;
      src = ./plugins/screenshot;
    };

    noSleep = {
      enable = true;
      src = ./plugins/no-sleep;
    };

    rotationLock = {
      enable = true;
      src = ./plugins/rotation-lock;
      # QML can't read osConfig.* itself -- ships both through
      # plugin_settings.json instead. The monitor is the same host-level
      # my.desktop.primaryOutput the niri/hyprland features use for the
      # autorotate listener this plugin kills and respawns.
      settings = {
        compositor = osConfig.my.desktop.compositor;
        monitor = osConfig.my.desktop.primaryOutput;
      };
    };
  };
}
