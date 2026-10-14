# hearth settings for the shell keybinds. Generated from features/bonfire/keybinds.nix so the single
# source of truth also drives the TUI: each action becomes a `keybind.<action>` chord string. Editing
# one is applied live by the keybind watcher (features/bonfire/home.nix -> hyprctl reload).
{ lib }:
let
  kb = import ./keybinds.nix;
in
lib.mapAttrs' (action: spec: lib.nameValuePair "keybind.${action}" {
  type = "string";
  default = spec.chord;
  label = spec.label;
  help = "Keybind for \"${spec.label}\". Chord format: \"SUPER + SHIFT + K\". Takes effect on the next Hyprland start (relogin); blank keeps the default.";
  tier = spec.tier or "advanced";
  scope = "runtime";
  reload = "keybind";
}) kb
