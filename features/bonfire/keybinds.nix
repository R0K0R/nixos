# Single source of truth for the configurable SHELL keybinds (features/bonfire/compositor.nix).
# Consumed twice: compositor.nix bakes these as the kb() defaults + generates the hl.bind calls, and
# hearth.nix turns each into a `keybind.<action>` string setting. Edit a chord in the hearth TUI and
# the keybind watcher (features/bonfire/home.nix) rewrites ~/.local/state/bonfire/keybinds.lua + runs
# `hyprctl reload`, so it applies live. Chord format is the fork's: "SUPER + SHIFT + K".
#
# NOTE: chords bake the literal "SUPER" (the modKey default). A host that changes my.hyprland.modKey
# would want these updated to match. Stage 1 = the bonfire shell binds only; features/hyprland's own
# window/workspace/mouse binds are not here yet.
{
  launcher        = { chord = "SUPER + space";          label = "App launcher";            tier = "common"; };
  flint           = { chord = "SUPER + Tab";            label = "Flint menu";              tier = "common"; };
  emoji           = { chord = "SUPER + slash";          label = "Emoji picker";            tier = "advanced"; };
  clipboard       = { chord = "SUPER + V";              label = "Clipboard history";       tier = "common"; };
  clipboard_wipe  = { chord = "SUPER + SHIFT + V";      label = "Clear clipboard";         tier = "advanced"; };
  lock            = { chord = "SUPER + Escape";         label = "Lock screen";             tier = "common"; };
  panic           = { chord = "SUPER + SHIFT + Escape"; label = "Panic (kill + lock)";     tier = "advanced"; };
  nightlight      = { chord = "SUPER + SHIFT + L";      label = "Night light toggle";      tier = "advanced"; };
  wallpaper       = { chord = "SUPER + Y";              label = "Wallpaper picker";        tier = "common"; };
  wallpaper_video = { chord = "SUPER + SHIFT + Y";      label = "Video wallpaper picker";  tier = "advanced"; };
  cava            = { chord = "SUPER + SHIFT + C";      label = "Cava underbar toggle";    tier = "advanced"; };
  waybar_cycle    = { chord = "SUPER + SHIFT + W";      label = "Cycle bar layout";        tier = "advanced"; };
  record          = { chord = "SUPER + F11";            label = "Screen record";           tier = "advanced"; };
  screenshot      = { chord = "SUPER + P";              label = "Screenshot (region)";     tier = "common"; };
  screenshot_full = { chord = "SUPER + CTRL + P";       label = "Screenshot (fullscreen)"; tier = "advanced"; };
  dockbar         = { chord = "SUPER + SHIFT + B";      label = "Dockbar toggle";          tier = "advanced"; };
}
