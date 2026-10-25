/*
  Session-safety pieces (features/core/epoch, features/session/fallback-session)
  on a synthetic copy of galaxybook4-pro360 with everything switched on,
  including what the real host leaves off (the PAM banner, strict handling of
  unrecorded generations) and a fixed rev, so the values do not move with
  every commit. `off` is the same host with the epoch, the fallback session
  and the guard switched OFF -- the real gb4 has them on since 2026-10-24.

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
    {
      my.epoch.enable = true;
      my.epoch.rev = "0000000000000000000000000000000000000000";
      my.fallback-session = {
        enable = true;
        normalSession = "start-hyprland";
        guard.enable = true;
        pamBanner.services = [ "login" "sshd" ];
        unrecordedIsMismatch = lib.mkForce true;
      };
    }
  ]; };
  off = mkHostWith { hostName = host; extraModules = [
    {
      my.epoch.enable = lib.mkForce false;
      my.epoch.hmSwitch.enable = true;
      my.fallback-session.enable = lib.mkForce false;
      my.fallback-session.guard.enable = lib.mkForce false;
    }
  ]; };

  c = on.config;
  homeLib = mkHomeLib host on;
  /*
    r0k0r's home is impermanent on gb4, and an impermanent home with an empty
    my.persist is refused (lib/home-persist.nix) -- his real list is in his
    home repo (~/config/home/persist.nix), which this flake cannot read. A
    one-entry stand-in keeps the home evaluable. `home` gets the epoch module
    only through the system (home-manager.sharedModules); `homeExplicit`
    also names homeLib.epochModule, which the module key must deduplicate.
  */
  persist = { my.persist.directories = [ "KSA" ]; };
  home = homeLib.mkHome {
    username = "r0k0r";
    modules = [ persist ];
  };
  homeExplicit = homeLib.mkHome {
    username = "r0k0r";
    modules = [ persist homeLib.epochModule ];
  };
  homeOff = (mkHomeLib host off).mkHome {
    username = "r0k0r";
    modules = [ persist ];
  };
  dm = c.services.displayManager.sessionData;
in
{
  toplevel = c.system.build.toplevel.drvPath;
  epoch = c.system.build.epoch;
  same = if c.system.build.epoch == off.config.system.build.epoch then "yes" else throw "enabling the features moved the epoch: ${toString (lib.subtractLists off.config.system.build.epochSurfacePaths c.system.build.epochSurfacePaths)} vs ${toString (lib.subtractLists c.system.build.epochSurfacePaths off.config.system.build.epochSurfacePaths)}";
  surfaceCategories = lib.concatStringsSep " " (lib.attrNames c.my.epoch.surfaceReport);
  surfaceSize = toString (lib.length c.system.build.epochSurfacePaths);
  recordUnit = c.systemd.units."nixos-epoch-record.service".unit.drvPath;
  sessions = lib.concatMapStringsSep " " (p: p.drvPath) c.services.displayManager.sessionPackages;
  # The guard: the aggregate greeters read is the rebuilt one (its own
  # assertion checks the merge), with an ignore-epoch id per guarded session,
  # the guarded ids first, and upstream's x11 wrapper kept.
  guardedDesktops = dm.desktops.drvPath;
  guardedNames =
    let
      n = dm.sessionNames;
      ignore = lib.filter (lib.hasSuffix "-ignore-epoch") n;
    in
    # Guarded first, the compositor's ahead of GNOME (my.gnome appends its
    # entry); ignore-epoch variants of exactly the guarded sessions; the
    # fallback unguarded. No kiosk: gb4's handoff is pinned to GNOME now.
    if
      lib.take 3 n == [ "hyprland" "hyprland-uwsm" "gnome" ]
      && ignore == [ "hyprland-ignore-epoch" "hyprland-uwsm-ignore-epoch" "gnome-ignore-epoch" ]
      && lib.elem "fallback" n
      && !(lib.elem "kiosk-firefox" n)
      && dm.autologinSession == "hyprland"
      && dm ? wrapper
    then
      lib.concatStringsSep " " dm.sessionNames
    else
      throw "sessionData: names ${toString dm.sessionNames}, autologin ${toString dm.autologinSession}, wrapper ${lib.boolToString (dm ? wrapper)}";
  guardOffAggregate =
    if off.config.services.displayManager.sessionData.desktops.drvPath != dm.desktops.drvPath then
      off.config.services.displayManager.sessionData.desktops.drvPath
    else
      throw "guard off still uses the guarded aggregate";
  guardScript =
    let
      t = c.my.fallback-session.internal.guardedSession.text or "";
    in
    if lib.hasInfix "GUARD_STRICT=1" t && lib.hasInfix "GUARD_USERS='benjamin r0k0r'" t then "strict, users benjamin r0k0r" else throw "guarded-session: unexpected header";
  pamLogin = if lib.hasInfix "epoch-login-banner" c.security.pam.services.login.text then lib.head (lib.filter (lib.hasInfix "epoch-banner") (lib.splitString "\n" c.security.pam.services.login.text)) else throw "pam banner not wired into login";
  homeActivation = home.activationPackage.drvPath;
  homeEpochModule =
    let
      cmds = home.config.home.extraBuilderCommands;
      n = lib.length (lib.filter (lib.hasInfix "> $out/epoch") (lib.splitString "\n" cmds));
    in
    if n == 1 && lib.hasInfix c.system.build.epoch cmds then cmds else throw "home: ${toString n} epoch lines in extraBuilderCommands";
  homeExplicitSame =
    if homeExplicit.activationPackage.drvPath == home.activationPackage.drvPath then "yes" else throw "naming homeLib.epochModule as well changed the home (module key not deduplicated)";
  homeOffNoEpoch =
    if lib.hasInfix "$out/epoch" homeOff.config.home.extraBuilderCommands then throw "home on a host with the epoch off records one" else "none";
  factsEpoch = builtins.toJSON homeLib.facts.epoch;
}
