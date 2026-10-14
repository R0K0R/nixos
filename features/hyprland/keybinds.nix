# Configurable discrete window/app keybinds owned by features/hyprland (stage 2 of the keybind
# configurer; the shell binds live in features/bonfire/keybinds.nix). Consumed by home.nix (baked as the
# hkb() inline defaults on the matching hl.bind calls) and by hearth.nix (turned into keybind.<action>
# string settings). The live override flows through the same bonfire keybind watcher + ~/.local/state/
# bonfire/keybinds.lua, so editing one in the TUI applies on `hyprctl reload`.
#
# Only the DISCRETE, named-action binds are here -- the structural groups (directional focus/move/
# resize, workspace numbers, mouse drag/resize, XF86 media/brightness, lid switch) stay inline in
# home.nix: they are rarely rechorded and don't map to a single tidy action.
{
  terminal     = { chord = "SUPER + Return";      label = "Terminal";             tier = "common"; };
  terminal_alt = { chord = "SUPER + T";           label = "Terminal (alt key)";   tier = "advanced"; };
  browser      = { chord = "SUPER + W";           label = "Web browser";          tier = "common"; };
  files        = { chord = "SUPER + B";           label = "File manager";         tier = "common"; };
  overview     = { chord = "SUPER + E";           label = "Window overview";      tier = "common"; };
  osk          = { chord = "SUPER + O";           label = "On-screen keyboard";   tier = "advanced"; };
  close_window = { chord = "SUPER + Q";           label = "Close window";         tier = "common"; };
  fullscreen   = { chord = "SUPER + F";           label = "Fullscreen";           tier = "common"; };
  float        = { chord = "SUPER + ALT + space"; label = "Toggle floating";      tier = "advanced"; };
  float_alt    = { chord = "SUPER + SHIFT + F";   label = "Toggle floating (alt)"; tier = "advanced"; };
  pin          = { chord = "SUPER + ALT + P";     label = "Pin window";           tier = "advanced"; };
}
