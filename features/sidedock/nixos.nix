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
      pipToggle = keyOpt "CTRL + P" "Toggle the focused window as a keystoned picture-in-picture card.";
      pip = keyOpt "P" "Hide the focused picture-in-picture card, or show the last hidden one.";
    };
  };

  # Entirely home-manager: a script plus Hyprland rules, binds and touch gestures
  # (features/sidedock/home.nix, hyprland.lua). The 5-finger dock swipes used to be
  # lisgd's (a system service, hence this file); they are Touch.gesture definitions in
  # hyprland.lua now (2026-10-08), and with nothing left for it lisgd does not run.
  config = lib.mkIf (config.my.sidedock.enable && config.my.desktop.compositor == "hyprland") {
  };
}
