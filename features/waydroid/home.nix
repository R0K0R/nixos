{ config, lib, pkgs, osConfig, ... }:

/*
  Waydroid's Hyprland half: Super+Q on the Waydroid window does not close it.
  Closing makes Android's hwcomposer segfault and Android loop its boot
  animation forever (see features/waydroid/nixos.nix); instead the window is
  hidden on the `waydroid` special workspace and Android's display is switched
  off, so it stops drawing (idle GPU) while it keeps running (music plays on).
  Launching Waydroid again -- the launcher entry or any app -- brings it back
  (the `waydroid` wrapper in nixos.nix).
*/
let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "waydroid"; };
  hide = pkgs.writeShellScript "waydroid-hide" ''
    a="$1"
    ${osConfig.programs.hyprland.package}/bin/hyprctl dispatch \
      "hl.dsp.window.move({workspace=\"special:waydroid\", follow=false, window=\"address:$a\"})" >/dev/null
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
