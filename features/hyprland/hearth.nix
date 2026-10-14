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
in
feel // keybinds
