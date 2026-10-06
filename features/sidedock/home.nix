{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "sidedock"; };
  cfg = osConfig.my.sidedock;
  mod = osConfig.my.hyprland.modKey;
  keystone = osConfig.my.hyprland.keystone.enable or false;

  # dock.sh is a plain file (no Nix-escaping headaches); this thin wrapper just puts
  # hyprctl + jq on its PATH. hyprctl comes from the RUNNING compositor's own
  # package so the IPC protocol always matches.
  dock = pkgs.writeShellScript "sidedock" ''
    export PATH=${lib.makeBinPath [ osConfig.programs.hyprland.package pkgs.jq pkgs.coreutils ]}''${PATH:+:$PATH}
    exec ${pkgs.writeShellScript "sidedock-impl" (builtins.readFile ./dock.sh)} "$@"
  '';

  # The dock's own throwaway terminal: keys.terminal spawns a kitty under this
  # class, which the auto-route rule below catches so it opens straight into the pile.
  dockTermClass = "sidedock-term";

in
# The Lua itself is ./hyprland.lua (lib/hypr-lua.nix).
lib.mkIf (cfg.enable && inScope && osConfig.my.desktop.compositor == "hyprland") (import ../../lib/hypr-lua.nix { inherit lib; } {
  name = "sidedock";
  src = ./hyprland.lua;
  values = {
    inherit mod keystone;
    inherit (cfg) keys;
    dock = "${dock}";
    termClass = dockTermClass;
    classes = cfg.apps ++ [ dockTermClass ];
  };
})
