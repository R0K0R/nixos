# hearth settings for the compositor: the live "feel" knobs (decoration/gaps/blur/animations, applied
# via `hyprctl keyword` by the watcher in features/bonfire/home.nix) + the discrete window/app keybinds
# (keybind.<action>, generated from features/hyprland/keybinds.nix, applied on hyprctl reload).
{ lib }:
let
  kb = import ./keybinds.nix;

  feel = {
    "hyprland.rounding" = {
      type = "int"; default = 16; label = "Corner rounding";
      help = "Window corner radius (px).";
      tier = "common"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 0; max = 32; unit = "px"; };
    };
    "hyprland.gaps_in" = {
      type = "int"; default = 2; label = "Inner gaps";
      help = "Gap between tiled windows (px).";
      tier = "common"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 0; max = 40; unit = "px"; };
    };
    "hyprland.gaps_out" = {
      type = "int"; default = 4; label = "Outer gaps";
      help = "Gap between windows and the screen edge (px).";
      tier = "common"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 0; max = 80; unit = "px"; };
    };
    "hyprland.border_size" = {
      type = "int"; default = 0; label = "Border width";
      help = "Window border thickness (px); 0 = no border.";
      tier = "advanced"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 0; max = 10; unit = "px"; };
    };
    "hyprland.blur.enabled" = {
      type = "bool"; default = true; label = "Blur";
      help = "Backdrop blur behind translucent surfaces.";
      tier = "common"; scope = "runtime"; reload = "hyprland";
    };
    "hyprland.blur.size" = {
      type = "int"; default = 8; label = "Blur size";
      help = "Blur radius.";
      tier = "advanced"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 1; max = 20; };
    };
    "hyprland.blur.passes" = {
      type = "int"; default = 3; label = "Blur passes";
      help = "Blur iterations (higher = softer, costlier).";
      tier = "advanced"; scope = "runtime"; reload = "hyprland";
      constraints = { min = 1; max = 6; };
    };
    "hyprland.animations.enabled" = {
      type = "bool"; default = true; label = "Animations";
      help = "Window/workspace animations.";
      tier = "common"; scope = "runtime"; reload = "hyprland";
    };
  };

  keybinds = lib.mapAttrs' (action: spec: lib.nameValuePair "keybind.${action}" {
    type = "string";
    default = spec.chord;
    label = spec.label;
    help = "Keybind for \"${spec.label}\". Chord format: \"SUPER + SHIFT + K\". Takes effect on the next Hyprland start (relogin); blank keeps the default.";
    tier = spec.tier or "advanced";
    scope = "runtime";
    reload = "keybind";
  }) kb;

  # Family modifiers: one knob shifts a whole directional-nav scheme at once (the direction keys --
  # arrows / HJKL / -,= -- stay fixed). Blank falls back to the default. e.g. set move_mod to
  # "SUPER + ALT" to move the whole "move window" family off SUPER+CTRL.
  modRec = default: label: help: {
    inherit default label help;
    type = "string"; tier = "advanced"; scope = "runtime"; reload = "keybind";
  };
  navmods = {
    "keybind.nav.focus_mod"         = modRec "SUPER"              "Focus modifier"            "Directional window focus (arrows).";
    "keybind.nav.move_mod"          = modRec "SUPER + CTRL"       "Move modifier"             "Directional window move (arrows + HJKL).";
    "keybind.nav.monitor_focus_mod" = modRec "SUPER + SHIFT"      "Focus-monitor modifier"    "Focus the screen in a direction (arrows).";
    "keybind.nav.monitor_move_mod"  = modRec "SUPER + SHIFT + CTRL" "Move-to-monitor modifier" "Move the window to the screen in a direction (arrows + HJKL).";
    "keybind.nav.resize_mod"        = modRec "SUPER"              "Resize modifier"           "Window resize (-, = ; SHIFT for vertical).";
    "keybind.workspace.switch_mod"  = modRec "SUPER"              "Workspace switch modifier" "SUPER+<n> scene switch (all screens).";
    "keybind.workspace.move_mod"    = modRec "SUPER + CTRL"       "Workspace move modifier"   "Send the active window to scene <n>.";
  };
in
feel // keybinds // navmods
