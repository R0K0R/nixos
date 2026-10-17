{ config, lib, osConfig, ... }:

let
  cfg = config.my.hyprland;
in
{
  imports = [ ./config.nix ];

  options.my.hyprland.enable = lib.mkEnableOption ''
    this user's Hyprland configuration: the Lua config (settings, binds, rules, hooks) written for
    this desktop -- synced per-monitor workspaces, the input lock, clamshell, monitor-scale
    persistence, the hidden startup splash and the discrete keybinds (editable through hearth).

    The compositor itself (programs.hyprland, the fork build with or without keystone, uwsm, the
    session .desktop) is the SYSTEM's: this needs my.desktop.compositor = "hyprland" on the host.
    The system's own Hyprland home configuration must not also apply to this account, or the two
    generated Lua configs would merge into one (see README.md, "What the system must provide")
  '';

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = osConfig.my.desktop.compositor == "hyprland";
        message = "my.hyprland.enable: this host's compositor is ${toString osConfig.my.desktop.compositor}, not hyprland (system option my.desktop.compositor).";
      }
    ];

    # Live "feel" knobs and the discrete keybinds (see ./hearth.nix).
    my.settings.fragments = [ (import ./hearth.nix) ];
  };
}
