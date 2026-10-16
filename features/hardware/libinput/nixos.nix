{ config, lib, ... }:

let
  cfg = config.my.libinput;
in
{
  options.my.libinput.enable = lib.mkEnableOption ''
    libinput touchpad support. Enabled by default under most desktopManagers, but
    this config runs a bare compositor under greetd with no desktopManager, so it
    has to be asked for
  '';

  config = lib.mkIf cfg.enable {
    services.libinput.enable = true;

    /*
      Touchpad "phantom finger": after a fold into tablet mode with a palm on the
      pad, every gesture needed one finger more (one finger did nothing). libinput
      only learns a slot's tool type from ABS_MT_TOOL_TYPE events, and resyncing a
      resumed touchpad skipped it, so a slot that was a palm when the touchpad was
      suspended stayed a palm forever. Diagnosed from Hyprland's log 2026-10-05.

      Upstream fixed it in d0e6d43 ("touchpad: sync the slot's tool type when
      syncing touch state"), released in 1.32.0; this is that commit verbatim.
      Applied only below 1.31.901 (the first release with it), so it retires
      itself when nixpkgs moves on. Until then, the immediate cure for a stuck
      touchpad is re-adding the device (hid-multitouch unbind/bind).
    */
    nixpkgs.overlays = [
      # The version test sits inside the value: an overlay's attribute NAMES must
      # not depend on `prev`, or the package-set fixpoint recurses forever.
      (final: prev: {
        libinput =
          if lib.versionOlder prev.libinput.version "1.31.901" then
            prev.libinput.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ./touchpad-sync-tool-type.patch ];
            })
          else
            prev.libinput;
      })
    ];
  };
}
