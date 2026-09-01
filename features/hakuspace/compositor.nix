{ config, lib, osConfig, ... }:

/*
  Haku Space's half of the compositor configuration -- the same seam
  features/dms/compositor.nix uses, and for the same reason: the compositor
  feature must not know which shell is running.

  These are the SHELL binds from upstream's src/wm/hyprland/config/keybinding.lua
  only. Its window-management, focus, workspace and mouse binds are not
  reproduced: features/hyprland already binds all of them, and that file is not
  installed here.

  mkAfter for the ordering reason documented at the top of
  features/dms/compositor.nix -- `hakuspace` sorts before `hyprland` in the
  alphabetical feature glob, so without it this lands above `local mod`.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  compositor = osConfig.my.desktop.compositor;
  mod = osConfig.my.hyprland.modKey;
  bin = name: "${config.home.homeDirectory}/.local/bin/${name}";
in
{
  config = lib.mkIf (enabled && compositor == "hyprland") {
    wayland.windowManager.hyprland.extraConfig = lib.mkAfter ''
      -- Launcher, menus and the notification centre.
      hl.bind("${mod} + R", hl.dsp.exec_cmd("rofi -show drun"))
      hl.bind("${mod} + SLASH", hl.dsp.exec_cmd("rofi -modi emoji -show emoji"))
      hl.bind("${mod} + TAB", hl.dsp.exec_cmd("${bin "hakumenu.sh"}"))
      hl.bind("${mod} + N", hl.dsp.exec_cmd("swaync-client -t -sw"))
      hl.bind("${mod} + V", hl.dsp.exec_cmd("${bin "clipboard_menu.sh"}"))
      hl.bind("${mod} + SHIFT + V", hl.dsp.exec_cmd("${bin "clipboard_menu.sh"} --wipe"))

      -- Session.
      hl.bind("${mod} + K", hl.dsp.exec_cmd("${bin "lock.sh"}"), { locked = true })
      hl.bind("${mod} + L", hl.dsp.exec_cmd("${bin "nightlight_toggle.sh"}"))

      -- Appearance: wallpaper, the cava underbar, and the bar layout cycle.
      hl.bind("${mod} + Y", hl.dsp.exec_cmd("${bin "wallpaper_select.sh"}"))
      hl.bind("${mod} + SHIFT + Y", hl.dsp.exec_cmd("${bin "wallpaper_video_select.sh"}"))
      hl.bind("${mod} + T", hl.dsp.exec_cmd("${bin "cava_manager.sh"}"))
      hl.bind("${mod} + SHIFT + W", hl.dsp.exec_cmd("${bin "waybar_manager.sh"} --cycle"))

      -- Capture.
      hl.bind("${mod} + F11", hl.dsp.exec_cmd("${bin "record.sh"}"))

      -- TWO BINDS MOVED OFF UPSTREAM'S DEFAULTS, because features/hyprland
      -- already owns those keys and a duplicate bind in Hyprland is decided by
      -- registration order rather than reported:
      --
      --   SUPER + W          upstream: dockbar toggle
      --                      here:     firefox (features/hyprland app spawns)
      --                      moved to: SUPER + SHIFT + B
      --
      --   SUPER + SHIFT + P  upstream: fullscreen screenshot
      --                      here:     dpms off (features/hyprland)
      --                      moved to: SUPER + CTRL + P
      --
      -- SUPER + P itself is free -- features/hyprland deliberately leaves it
      -- for the shell layer -- so the plain screenshot keeps its upstream key.
      --
      -- LUA COMMENTS, NOT NIX ONES. This block is inside a Lua string; a
      -- /* */ comment here reaches Hyprland verbatim and the config dies with
      -- "unexpected symbol near '/'" at session start. Caught by parsing the
      -- generated file rather than by evaluation, which cannot see inside a
      -- string literal.
      hl.bind("${mod} + P", hl.dsp.exec_cmd("${bin "screenshot.sh"}"))
      hl.bind("${mod} + CTRL + P", hl.dsp.exec_cmd("${bin "screenshot.sh"} --fullscreen"))
      hl.bind("${mod} + SHIFT + B", hl.dsp.exec_cmd("${bin "dockbar_manager.sh"} --toggle"))

      -- Glassmorphism for the bar and the launcher, matching what
      -- features/hyprland enables compositor-side. A layer surface has to opt
      -- into blur; only windows get it automatically.
      hl.layer_rule({ match = { namespace = "^(waybar)$" }, blur = true, ignore_alpha = 0.05 })
      hl.layer_rule({ match = { namespace = "^(rofi)$" }, blur = true, ignore_alpha = 0.05 })
      hl.layer_rule({ match = { namespace = "^(swaync.*)$" }, blur = true, ignore_alpha = 0.05 })
    '';
  };
}
