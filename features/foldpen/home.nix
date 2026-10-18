{ config, lib, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "foldpen"; };
  cfg = osConfig.my.foldpen;
in
# PC-side keys for the same toggles the phone's 3-finger gestures drive.
lib.mkIf (cfg.enable && inScope && osConfig.my.desktop.compositor == "hyprland")
  (import ../../lib/hypr-lua.nix { inherit lib; } {
    name = "foldpen";
    src = ./hyprland.lua;
    values = {
      mod = osConfig.my.hyprland.modKey;
      foldpen = lib.getExe osConfig.services.foldpen.package;
    };
  })
