/*
  session = { kiosk = "<package>"; }: one program under cage and nothing
  else -- the handover type's firefox -- and a login that cannot be anything
  else.

  THE LAUNCHER. Built the way features/session/fallback-session builds its
  session: a script from the SYSTEM package set. cage and the program are
  the host's pkgs (the registry resolves the attribute name against them),
  so a kiosk user needs no home-manager generation and no nix access to get
  a working session -- which is the point, since the handover type has
  neither. One launcher per distinct package, not per user: two handover
  accounts with the same browser share it. `cage -s` keeps VT switching, so
  the machine's owner can still reach a text console. It is offered to
  greeters as "Kiosk (<prog>)" (harmless for anyone else to pick: it runs
  the program as them).

  PINNING, ENFORCED BELOW THE GREETER. Hiding the other entries from a
  greeter would pin nothing: the greeter is a UI, dms-greeter remembers the
  last session per user, tuigreet lets anyone type a command, and the
  session greetd starts is whatever string the greeter sends. What greetd
  does with that string is fixed, though (greetd 0.10 session/worker.rs):
  as the user, it execs

    /bin/sh -c '[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec <cmd>'

  (source_profile, greetd's default; asserted below). So the first lines of
  /etc/profile -- mkBefore, ahead of its own "sourced once" guard, so a
  greeter-supplied __ETC_PROFILE_SOURCED cannot skip them -- exec the
  user's launcher when the real uid (id -u, an absolute path: nothing from
  the environment) is a kiosk account. The requested command is never
  reached, whatever the greeter offered, remembered or was typed into. The
  launcher sources /etc/set-environment itself, since it replaces the rest
  of /etc/profile (/etc/set-environment is what /etc/profile sources
  first). The greeter's environment is trusted here: it is the
  system's own greeter process, and neither tuigreet nor dms-greeter lets
  the person at the keyboard set variables.

  EVERY OTHER WAY IN, decided per path:

    VT login (getty + login)  allowed: the account's login SHELL is the
                              launcher, so a text-console login starts the
                              same cage session on that VT.
    ssh                       refused: sshd DenyUsers, plus a PAM account
                              rule. There is no seat over ssh, and nothing a
                              borrower needs.
    su                        refused at PAM account (pam_succeed_if), root
                              included -- root has runuser/machinectl if it
                              really wants. su -l has no PAM service on
                              NixOS ("other" denies).
    run0, machinectl shell,   root or polkit-admin only; they get the same
    runuser, systemd-run      launcher as the shell, or whatever root asks.
    `-c <command>`            the launcher refuses any argument: that is
                              what sshd, su -c, runuser -c and scp/sftp
                              would hand a login shell.
    su -s <shell>             the launcher is not in /etc/shells (a plain
                              path, not a shellPackage, so NixOS does not
                              add it), so util-linux su ignores -s for
                              non-root callers.

  What runs INSIDE the session is the user's: if the program can start other
  programs, they run as him, under the same session, gone at logout
  (tmpfs-home.nix's KillOnlyUsers). That is the kiosk's program's business,
  not the login's.
*/
{ config, lib, pkgs, ... }:

let
  kioskUsers = lib.filterAttrs (_: u: u.kiosk != null) config.my.users;
  names = lib.attrNames kioskUsers;
  kioskPkgs = lib.unique (lib.mapAttrsToList (_: u: u.kiosk) kioskUsers);

  progOf = pkg: baseNameOf (lib.getExe pkg);

  launcher =
    pkg:
    pkgs.writeShellScriptBin "kiosk-shell-${progOf pkg}" ''
      if [ $# -gt 0 ]; then
        echo "this account runs ${progOf pkg} and nothing else" >&2
        exit 1
      fi
      # The runtime path, not system.build.setEnvironment: that would make
      # the login shell depend on environment.variables, which depends on
      # the session packages this launcher is one of.
      . /etc/set-environment
      exec ${lib.getExe pkgs.cage} -s -- ${lib.getExe pkg}
    '';

  entry =
    pkg:
    let
      name = "kiosk-${progOf pkg}";
    in
    (pkgs.writeTextDir "share/wayland-sessions/${name}.desktop" ''
      [Desktop Entry]
      Name=Kiosk (${progOf pkg})
      Comment=${progOf pkg} alone, full screen, nothing else
      Exec=${launcherExe pkg}
      Type=Application
    '').overrideAttrs
      {
        passthru = {
          providedSessions = [ name ];
          # Only system code runs in it: my.fallback-session.guard links it
          # through unchanged.
          epochGuard = false;
        };
      };

  launcherExe = pkg: "${launcher pkg}/bin/kiosk-shell-${progOf pkg}";

  /*
    The passwd entry names the launcher through /run/current-system/sw, not
    by store path: NixOS refuses a store-path string that is not a
    shellPackage as a shell (utils.toShellPath), and a shellPackage would be
    added to /etc/shells -- which must not happen (su -s, below).
  */
  shellPath = pkg: "/run/current-system/sw/bin/kiosk-shell-${progOf pkg}";

  uidOf = n: config.users.users.${n}.uid;

  pin = lib.concatMapStrings (n: ''
    ${toString (uidOf n)}) exec ${launcherExe kioskUsers.${n}.kiosk} ;;
  '') names;

  pamPkg = config.security.pam.package;
in
{
  config = lib.mkIf (kioskUsers != { }) {
    services.displayManager.sessionPackages = map entry kioskPkgs;

    environment.systemPackages = map launcher kioskPkgs;

    users.users = lib.genAttrs names (n: {
      shell = shellPath kioskUsers.${n}.kiosk;
    });

    environment.etc.profile.text = lib.mkBefore ''
      # Kiosk accounts get their one program, whatever session was asked for
      # (features/core/users/kiosk.nix).
      case "$(${pkgs.coreutils}/bin/id -u)" in
        ${pin}
      esac
    '';

    services.openssh.settings.DenyUsers = lib.mkIf config.services.openssh.enable names;

    security.pam.services = lib.genAttrs ([ "su" ] ++ lib.optional config.services.openssh.enable "sshd") (svc: {
      rules.account.kiosk-pin = {
        order = config.security.pam.services.${svc}.rules.account.unix.order - 20;
        control = "required";
        modulePath = "${pamPkg}/lib/security/pam_succeed_if.so";
        args = [ "quiet" "user" "notin" (lib.concatStringsSep ":" names) ];
      };
    });

    assertions =
      [
        {
          assertion = (config.services.greetd.settings.general.source_profile or true) != false;
          message = "kiosk users (${lib.concatStringsSep ", " names}) are pinned through /etc/profile, which greetd only sources with general.source_profile = true.";
        }
      ]
      ++ lib.concatMap (n: [
        {
          assertion = kioskUsers.${n}.shell == null;
          message = "my.users.${n}: a kiosk account's login shell is its launcher; drop `shell`.";
        }
        {
          assertion = kioskUsers.${n}.sshKeys == [ ];
          message = "my.users.${n}: a kiosk account cannot log in over ssh (DenyUsers); drop sshKeys.";
        }
        {
          assertion = uidOf n != null;
          message = "my.users.${n}: a kiosk account needs a pinned uid (the /etc/profile pin matches on it).";
        }
      ]) names;
  };
}
