/*
  The SYSTEM half of foldpen (a Galaxy Z Fold 6 as a stylus for Hyprland,
  ~/git_shit/foldpen): the grant. foldpen creates virtual pen and touch
  devices through /dev/uinput -- seat-wide input injection, any process of the
  account could type into any window, the lock screen included -- so which
  accounts may do that is the admin's decision, made here. And the port, open
  for Wi-Fi (`foldpen usb` goes through adb reverse instead).

  The daemon, its user unit and its Hyprland keys are the home half, my.foldpen
  in a home repo, since 2026-10-27. Before that, the upstream NixOS module ran
  the daemon as a system user unit, started in every account's session --
  including ones without the grant, where it failed and restarted.
*/
{ config, lib, ... }:

let
  cfg = config.my.foldpen;
in
{
  options.my.foldpen = {
    enable = lib.mkEnableOption "foldpen's grant: uinput for the accounts below, and the daemon's port";
    users = import ../../../lib/user-scope.nix { inherit lib config; };
    port = lib.mkOption {
      type = lib.types.port;
      default = 7392;
      description = "The daemon's TCP port, opened for Wi-Fi. The home half listens on it.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.uinput.enable = true;
    users.users = lib.genAttrs cfg.users (_: { extraGroups = [ "uinput" ]; });
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
