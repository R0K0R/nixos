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

  # Almost entirely home-manager -- a script plus Hyprland rules and binds
  # (features/sidedock/home.nix, hyprland.lua). The one system-level piece is the
  # touchscreen gesture, since lisgd (features/touch-gestures) is a system service:
  # FIVE fingers, right-to-left shows the dock and left-to-right hides it.
  #
  # Five because every smaller count is taken. It used to be one finger swiped in from
  # the right edge, which collided with touch border-resize (patches/keystone/10) on any
  # window touching that edge; three and four fingers belong to the compositor's live
  # touch gestures (patches/keystone/11); two is app scrolling. lisgd can't do taps (its
  # gestures are swipes only), so a multi-finger tap was not an option without patching it.
  #
  # Directions are PHYSICAL (followRotation = false): the dock sits on the panel's
  # physical right edge at every rotation, so "toward the left" means the same motion of
  # the hand however the picture is turned. lisgd fires on completion only.
  config = lib.mkIf (config.my.sidedock.enable && config.my.desktop.compositor == "hyprland") {
    my.touch-gestures.extraGestures = [
      "5,RL,*,*,hyprctl eval 'SideDockShow()'"
      "5,LR,*,*,hyprctl eval 'SideDockHide()'"
    ];
    my.touch-gestures.followRotation = lib.mkDefault false;
  };
}
