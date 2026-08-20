{ config, lib, pkgs, ... }:

let
  cfg = config.my.samsung-ecosystem;
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.samsung-ecosystem = {
    enable = lib.mkEnableOption "Galaxy Buds Client and rQuickShare Packages";
    budsStartUp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Start Galaxy Buds Client in tray when startup";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = pkgSet.system;

    /*
      Galaxy Buds client in the tray from login. /StartMinimized is the app's
      own flag, read straight out of the shipped GalaxyBudsClient.dll (its
      settings UI calls it "Start minimized on system boot") -- without it the
      main window opens on every login. systemd user service on
      graphical-session.target, same pattern as lisgd and dms.service:
      compositor-agnostic (uwsm activates the target under both hyprland and
      niri), unlike an exec-once in one compositor's config.
    */
    systemd.user.services.galaxy-buds-client = lib.mkIf cfg.budsStartUp {
      description = "Galaxy Buds client (tray)";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe pkgs.galaxy-buds-client} /StartMinimized";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
