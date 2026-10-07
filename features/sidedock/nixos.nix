{ config, lib, ... }:

/*
  Right-edge side dock for Hyprland, imported 2026-10-05 from sihooleebd/nixos
  (features/sidedock, commits 1d5e9bf and 0a7686c). Adapted here: keys are options (his
  SUPER+D / SUPER+left/right collide with this config's column toggle and focus
  binds), dock.sh's geometry is in logical pixels and honours rotation and the
  monitor's reserved area (his assumed scale 1 and a 56px waybar), and the
  fullscreen/drag guards live in this feature instead of features/hyprland.
*/
let
  keyOpt = default: description: lib.mkOption {
    type = lib.types.str;
    inherit default description;
  };
in
{
  options.my.sidedock = {
    enable = lib.mkEnableOption
      "right-edge slide-out dock -- light apps park off-screen and cycle in one at a time (Hyprland only)";
    # Accounts this feature applies to; defaults to the primary user.
    users = import ../../lib/user-scope.nix { inherit lib config; };
    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "org.kde.dolphin" ];
      description = ''
        Window classes (bare regex bodies, each wrapped as ^(<x>)$) that AUTO-open
        into the dock -- floated to the dock shape, tagged 'dock', without grabbing
        focus. Only list classes that should ALWAYS live in the dock; dual-use apps
        (a terminal, dolphin) are better pushed in on demand with keys.dockToggle.
      '';
    };
    # Key combos after the mod key, in Hyprland's "A + B" form.
    keys = {
      toggle = keyOpt "S" "Show / park the whole pile.";
      dockToggle = keyOpt "CTRL + S" "Move the focused window into the dock, or back out (the dock as a workspace).";
      terminal = keyOpt "ALT + T" "A terminal that opens straight into the dock.";
      prev = keyOpt "ALT + left" "Shift the pile back one window.";
      next = keyOpt "ALT + right" "Shift the pile forward one window.";
      pip = keyOpt "P" "Toggle the focused window as a keystoned picture-in-picture card.";
    };
  };

  # Almost entirely home-manager -- a script plus Hyprland rules and binds
  # (features/sidedock/home.nix, hyprland.lua). The one system-level piece is the
  # touchscreen gesture, since lisgd (features/touch-gestures) is a system service:
  # a ONE-finger swipe in from the right edge (edge R, right-to-left) toggles the dock,
  # like a phone's side panel. One finger is safe only because it must START at the
  # edge -- lisgd does not grab, so the app underneath sees the touch as well.
  # SideDockToggle is a Lua global in hyprland.lua, hence `eval`. lisgd fires on
  # completion only: unlike the touchpad's 4-finger swipe this is not interactive.
  config = lib.mkIf (config.my.sidedock.enable && config.my.desktop.compositor == "hyprland") {
    my.touch-gestures.extraGestures = [ "1,RL,R,*,hyprctl eval 'SideDockToggle()'" ];
  };
}
