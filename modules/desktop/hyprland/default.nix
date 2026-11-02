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

    The host's compositor (programs.hyprland: the fork's `nixos` build, uwsm, the session .desktop)
    is the SYSTEM's: this needs my.desktop.compositor = "hyprland" on the host. The patched one this
    desktop runs is this home's (keystone.enable, package below); the session entry starts it.
    The system's own Hyprland home configuration must not also apply to this account, or the two
    generated Lua configs would merge into one (see README.md, "What the system must provide")
  '';

  options.my.hyprland.keystone.enable = lib.mkEnableOption ''
    the keystone compositor: the host's Hyprland build (the R0K0R/Hyprland fork's `nixos` branch)
    with ./trapezoid.patch -- the "dock"-tagged windows rendered as a perspective trapezoid, the
    decoration:keystone_* options, scale-to-fit, the continuous dock gestures (dockpile, move), the
    overview, Lua touch and pen. The stock compositor rejects those keys and actions'';

  options.my.hyprland.package = lib.mkOption {
    type = lib.types.package;
    default =
      let
        host = osConfig.programs.hyprland.package.unwrapped;
      in
      if cfg.keystone.enable then
        host.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./trapezoid.patch ];
          env = old.env // {
            GIT_BRANCH = "${old.env.GIT_BRANCH or "nixos"}+trapezoid";
          };
        })
      else
        host;
    defaultText = lib.literalMD "the host's compositor, with ./trapezoid.patch under `keystone.enable`";
    description = ''
      This account's compositor: installed in its profile, where the system's session entry finds
      and starts it, and the hyprctl the desktop's scripts use.
    '';
  };

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
