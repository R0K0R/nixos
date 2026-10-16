/*
  Session-safety pieces (features/core/epoch, features/session/fallback-session)
  switched ON in a synthetic copy of galaxybook4-pro360 -- the real hosts keep
  them off, so this is the only place their enabled branches are evaluated.

  Every attribute is a string (drvPaths, the epoch), so forcing the whole set
  evaluates everything without building anything. Run it with builds disabled
  (tests/session-safety-eval.sh); an IFD that is not already built must make
  this FAIL, not build. The package set is gb4's own, so emacs/doom's IFD is
  the one the real host already realised.

  `same` checks the property the epoch rests on: switching the epoch feature
  and the fallback session on must not move the epoch itself (none of their
  definitions may reach the surface -- in particular the PAM banner's
  pam_exec comes from the same pam derivation as pam_unix).
*/
{ lib, mkHostWith, mkHomeLib }:

let
  host = "galaxybook4-pro360";

  on = mkHostWith { hostName = host; extraModules = [
    ({ config, ... }: {
      my.epoch.enable = true;
      my.epoch.rev = "0000000000000000000000000000000000000000";
      my.fallback-session = {
        enable = true;
        normalSession = "start-hyprland";
        guardSessions = [ config.programs.hyprland.package ];
        pamBanner.services = [ "login" "sshd" ];
        unrecordedIsMismatch = true;
      };
    })
  ]; };
  off = mkHostWith { hostName = host; };

  c = on.config;
  homeLib = mkHomeLib host on;
  home = homeLib.mkHome {
    username = "r0k0r";
    modules = [ homeLib.epochModule ];
  };
in
{
  toplevel = c.system.build.toplevel.drvPath;
  epoch = c.system.build.epoch;
  same = if c.system.build.epoch == off.config.system.build.epoch then "yes" else throw "enabling the features moved the epoch: ${toString (lib.subtractLists off.config.system.build.epochSurfacePaths c.system.build.epochSurfacePaths)} vs ${toString (lib.subtractLists c.system.build.epochSurfacePaths off.config.system.build.epochSurfacePaths)}";
  surfaceCategories = lib.concatStringsSep " " (lib.attrNames c.my.epoch.surfaceReport);
  surfaceSize = toString (lib.length c.system.build.epochSurfacePaths);
  recordUnit = c.systemd.units."nixos-epoch-record.service".unit.drvPath;
  sessions = lib.concatMapStringsSep " " (p: p.drvPath) c.services.displayManager.sessionPackages;
  pamLogin = if lib.hasInfix "epoch-login-banner" c.security.pam.services.login.text then lib.head (lib.filter (lib.hasInfix "epoch-banner") (lib.splitString "\n" c.security.pam.services.login.text)) else throw "pam banner not wired into login";
  homeActivation = home.activationPackage.drvPath;
  homeEpochModule = home.config.home.extraBuilderCommands;
}
