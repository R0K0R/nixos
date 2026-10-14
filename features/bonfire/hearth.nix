# hearth settings for the bonfire shell: the keybinds (from keybinds.nix) + the shell's own
# `~/bonfire-control/main_setting.sh` values (the "bjillion settings" the rofi menu used to edit). The
# latter are materialised BACK into main_setting.sh by the bonfire-control-sync watcher
# (features/bonfire/home.nix), so the ~8 scripts that `source` it stay untouched -- hearth is just the
# new editor. Defaults mirror the shipped main_setting.sh.
{ lib }:
let
  kb = import ./keybinds.nix;

  keybinds = lib.mapAttrs' (action: spec: lib.nameValuePair "keybind.${action}" {
    type = "string";
    default = spec.chord;
    label = spec.label;
    help = "Keybind for \"${spec.label}\". Chord format: \"SUPER + SHIFT + K\". Takes effect on the next Hyprland start (relogin); blank keeps the default.";
    tier = spec.tier or "advanced";
    scope = "runtime";
    reload = "keybind";
  }) kb;

  # main_setting.sh values. scope=runtime: the watcher rewrites main_setting.sh on change and the shell
  # scripts re-source it each run, so most apply on next use. Paths keep a literal $HOME (the shim emits
  # them unquoted-expanded into the shell file).
  r = type: default: label: help: tier: extra: ({ inherit type default label help tier; scope = "runtime"; reload = "bonfire"; } // extra);
  control = {
    "bonfire.nightlight.temp"                 = r "int"  4000 "Night light temperature" "Colour temperature (K) while night light is on." "common"   { constraints = { min = 1000; max = 6500; unit = "K"; }; };
    "bonfire.wallpaper.dir"                    = r "string" "$HOME/Pictures/Wallpapers" "Wallpaper folder" "Where the wallpaper picker looks." "common" { };
    "bonfire.wallpaper.video_dir"             = r "string" "$HOME/Videos/Wallpapers" "Video wallpaper folder" "Folder of lively (video) wallpapers." "advanced" { };
    "bonfire.wallpaper.interval"              = r "int"  300 "Random wallpaper interval" "Seconds between random wallpaper changes." "common" { constraints = { min = 10; max = 7200; unit = "s"; }; };
    "bonfire.wallpaper.accent_from_wallpaper" = r "bool" true "Accent from wallpaper" "Derive the theme accent from the current wallpaper." "common" { };
    "bonfire.wallpaper.awww_opts"            = r "string" "--transition-type random --transition-step 90 --transition-fps 60" "Wallpaper transition" "awww transition options." "advanced" { };
    "bonfire.screenshot.dir"                 = r "string" "$HOME/Pictures/Screenshots" "Screenshot folder" "Where screenshots are saved." "common" { };
    "bonfire.record.dir"                     = r "string" "$HOME/Videos" "Recording folder" "Where screen recordings are saved." "common" { };
    "bonfire.record.command"                 = r "string" "wl-screenrec" "Recorder command" "Screen-recording binary." "advanced" { };
    "bonfire.record.opts"                    = r "string" "--max-fps 60 --codec avc --encode-pixfmt nv12" "Recorder options" "wl-screenrec options." "advanced" { };
    "bonfire.idle.clock_font_size"           = r "int"  10 "Idle clock font size" "bonfire.sh idle-screen clock size." "advanced" { constraints = { min = 4; max = 40; }; };
    "bonfire.idle.general_font_size"         = r "int"  11 "Idle general font size" "bonfire.sh idle-screen text size." "advanced" { constraints = { min = 4; max = 40; }; };
    "bonfire.idle.terminal_font_size"        = r "int"  14 "Idle terminal font size" "bonfire.sh idle-screen terminal size." "advanced" { constraints = { min = 4; max = 40; }; };
    "bonfire.exit.ram_threshold_mb"          = r "int"  300 "Exit RAM warning (MB)" "exit.sh warns if RAM use exceeds this on quit." "advanced" { constraints = { min = 0; max = 64000; unit = "MB"; }; };
    "bonfire.exit.app_list"                  = r "list" [ ] "Exit kill list" "Extra apps to gracefully close then force-kill when leaving the session." "advanced" { };
    "bonfire.waybar.user_modes"              = r "list" [ ] "Custom waybar modes" "Names of custom waybar layouts in ~/bonfire-control/waybar/<name>/." "advanced" { };
  };
in
keybinds // control
