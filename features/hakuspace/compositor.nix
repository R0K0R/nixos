{ config, lib, osConfig, ... }:

/*
  Haku Space's half of the compositor configuration -- the same seam
  features/dms/compositor.nix uses, and for the same reason: the compositor
  feature must not know which shell is running.

  These are the SHELL binds from upstream's src/wm/hyprland/config/keybinding.lua
  only. Its window-management, focus, workspace and mouse binds are not
  reproduced: features/hyprland already binds all of them, and that file is not
  installed here.

  mkAfter (the lib/hypr-lua.nix default) for the ordering reason documented at
  the top of features/dms/compositor.nix -- `hakuspace` sorts before
  `hyprland` in the alphabetical feature glob.
*/

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "hakuspace"; };
  cfg = osConfig.my.hakuspace;
  enabled = cfg.enable && inScope;

  compositor = osConfig.my.desktop.compositor;
in
{
  # The Lua itself is ./hyprland.lua (lib/hypr-lua.nix).
  config = lib.mkIf (enabled && compositor == "hyprland") (import ../../lib/hypr-lua.nix { inherit lib; } {
    name = "hakuspace";
    src = ./hyprland.lua;
    values = {
      mod = osConfig.my.hyprland.modKey;
      binDir = "${config.home.homeDirectory}/.local/bin";
    };
  });
}
