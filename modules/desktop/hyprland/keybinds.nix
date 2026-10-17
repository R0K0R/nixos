# Configurable discrete window/app keybinds owned by modules/desktop/hyprland (stage 2 of the keybind
# configurer; the shell binds live in modules/desktop/bonfire/keybinds.nix). Consumed by home.nix (baked as the
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

  # --- bucket 1: the remaining discrete binds (apps, screenshots, dpms, media/brightness/playback) ---
  office          = { chord = "SUPER + L";              label = "Office suite";            tier = "advanced"; };
  emacs           = { chord = "SUPER + SHIFT + E";      label = "Emacs";                   tier = "advanced"; };
  ime_toggle      = { chord = "Hangul";                 label = "Input method toggle";     tier = "advanced"; };
  display_off     = { chord = "SUPER + SHIFT + P";      label = "Display off (DPMS)";      tier = "advanced"; };
  shot_region     = { chord = "Print";                  label = "Screenshot region (clip)"; tier = "advanced"; };
  shot_output     = { chord = "CTRL + Print";           label = "Screenshot screen (clip)"; tier = "advanced"; };
  shot_window     = { chord = "ALT + Print";            label = "Screenshot window (clip)"; tier = "advanced"; };
  shot_save       = { chord = "SUPER + SHIFT + S";      label = "Screenshot (save)";       tier = "advanced"; };
  vol_mute        = { chord = "XF86AudioMute";          label = "Volume mute";             tier = "advanced"; };
  vol_down        = { chord = "XF86AudioLowerVolume";   label = "Volume down";             tier = "advanced"; };
  vol_up          = { chord = "XF86AudioRaiseVolume";   label = "Volume up";               tier = "advanced"; };
  brightness_down = { chord = "XF86MonBrightnessDown";  label = "Brightness down";         tier = "advanced"; };
  brightness_up   = { chord = "XF86MonBrightnessUp";    label = "Brightness up";           tier = "advanced"; };
  media_play      = { chord = "XF86AudioPlay";          label = "Play / pause";            tier = "advanced"; };
  media_next      = { chord = "XF86AudioNext";          label = "Media next";              tier = "advanced"; };
  media_prev      = { chord = "XF86AudioPrev";          label = "Media previous";          tier = "advanced"; };
  media_next_alt  = { chord = "SUPER + bracketright";   label = "Media next (alt)";        tier = "advanced"; };
  media_prev_alt  = { chord = "SUPER + bracketleft";    label = "Media previous (alt)";    tier = "advanced"; };
}
