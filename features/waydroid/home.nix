{ config, lib, pkgs, osConfig, ... }:

/*
  Waydroid's Hyprland half: Super+Q on the Waydroid window does not close it.
  Closing makes Android's hwcomposer segfault and Android loop its boot
  animation forever (see features/waydroid/nixos.nix); instead the window is
  hidden on the `waydroid` special workspace and Android's display is switched
  off, so it stops drawing (idle GPU) while it keeps running (music plays on) --
  unless app windows of multi-window mode are open, which share that display.
  Launching Waydroid again -- the launcher entry or any app -- brings it back
  (the `waydroid` wrapper in nixos.nix).
*/
let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "waydroid"; };
  hide = pkgs.writeShellScript "waydroid-hide" ''
    a="$1"
    # A pinned window (a sidedock PiP) refuses a special workspace and stayed on
    # screen with its display off -- the black window. Unpin first; the
    # `waydroid` wrapper re-pins it (it keeps its pip tag) on the way back.
    ${osConfig.programs.hyprland.package}/bin/hyprctl dispatch \
      "hl.dsp.window.pin({action=\"off\", window=\"address:$a\"})" >/dev/null
    ${osConfig.programs.hyprland.package}/bin/hyprctl dispatch \
      "hl.dsp.window.move({workspace=\"special:waydroid\", follow=false, window=\"address:$a\"})" >/dev/null
    # Multi-window mode: each Android app has its own window (class
    # waydroid.<package>) on the same Android display, so sleeping it took every
    # app window down with the full UI. Keep the display on while any is open.
    ${osConfig.programs.hyprland.package}/bin/hyprctl clients -j \
      | ${lib.getExe pkgs.jq} -e 'any(.[]; .class | startswith("waydroid."))' >/dev/null && exit 0
    [ -w /run/waydroid-display ] && echo off > /run/waydroid-display
  '';
in
lib.mkIf (osConfig.my.waydroid.enable && inScope && osConfig.my.desktop.compositor == "hyprland")
  (import ../../lib/hypr-lua.nix { inherit lib; } {
    name = "waydroid";
    src = ./hyprland.lua;
    values = {
      mod = osConfig.my.hyprland.modKey;
      hide = "${hide}";
    };
  })
