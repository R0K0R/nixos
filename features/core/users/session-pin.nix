/*
  SESSION PINS: "this uid always runs this command", whatever the greeter
  offered, remembered or had typed into it. One mechanism for every pinned
  session kind: kiosk.nix pins a kiosk account to its cage launcher,
  features/session/gnome pins a { desktop = "gnome"; } account to its GNOME
  launcher. Each fills my.internal.sessionPins.<user>; this file turns the
  set into the first lines of /etc/profile.

  WHY /etc/profile. Hiding the other entries from a greeter would pin
  nothing: the greeter is a UI, dms-greeter remembers the last session per
  user, tuigreet lets anyone type a command, and the session greetd starts
  is whatever string the greeter sends. What greetd does with that string is
  fixed, though (greetd 0.10 session/worker.rs): as the user, it execs

    /bin/sh -c '[ -f /etc/profile ] && . /etc/profile; [ -f $HOME/.profile ] && . $HOME/.profile; exec <cmd>'

  (source_profile, greetd's default; asserted below). So the first lines of
  /etc/profile -- mkBefore, ahead of its own "sourced once" guard, so a
  greeter-supplied __ETC_PROFILE_SOURCED cannot skip them -- exec the
  account's command when the real uid (id -u, an absolute path: nothing from
  the environment) is a pinned account. The requested command is never
  reached. The command runs INSTEAD of the rest of /etc/profile, so it
  sources /etc/set-environment itself (what /etc/profile sources first).

  TWO SCOPES, per pin:

    everywhere   (greeterOnly = false; kiosk) every shell that reads
                 /etc/profile execs the command. Right for a kiosk, whose
                 login shell IS its launcher and which has no shell to give
                 anyone: every way in either lands in the launcher or is
                 refused (kiosk.nix).
    greeter only (greeterOnly = true; desktops) only the shell greetd
                 started: its parent process is greetd's session worker
                 (/proc/$PPID/comm = "greetd"; the worker forks the shell and
                 nothing else). A desktop has terminals, and login shells
                 inside it read /etc/profile too -- `bash -l`, an IDE's
                 `bash -lc` for the environment, and gnome-session itself,
                 which re-executes through `$SHELL -l -c` (its
                 maybe_reexec_with_login_shell; the GNOME launcher passes
                 --no-reexec, but nothing should depend on that). Pinning
                 those would exec a second session inside the first, or loop.
                 Their parent is never greetd, so they are left alone. A
                 process that names itself "greetd" and then starts a login
                 shell gets the pinned command one more time: the pin errs
                 towards the pinned session, never away from it. A VT login
                 (getty -> login -> the account's shell) is not pinned: its
                 parent is login. The account keeps a real login shell, the
                 same shell its desktop's terminal gives it.

  The greeter's environment is trusted here: it is the system's own greeter
  process, and neither tuigreet nor dms-greeter lets the person at the
  keyboard set variables.
*/
{ config, lib, pkgs, ... }:

let
  pins = config.my.internal.sessionPins;
  names = lib.attrNames pins;
  uidOf = n: config.users.users.${n}.uid;

  caseLine =
    n:
    let
      p = pins.${n};
    in
    if p.greeterOnly then
      ''
        ${toString (uidOf n)}) { IFS= read -r __session_pin_parent < "/proc/$PPID/comm"; } 2>/dev/null
          [ "''${__session_pin_parent-}" = greetd ] && exec ${p.command}
          unset __session_pin_parent ;;
      ''
    else
      ''
        ${toString (uidOf n)}) exec ${p.command} ;;
      '';
in
{
  options.my.internal.sessionPins = lib.mkOption {
    internal = true;
    default = { };
    description = ''
      user -> the command a greetd login of that account runs, whatever the
      greeter asked for (see the header of this file). Filled by the session
      kinds that pin (kiosk.nix, features/session/gnome); a user can have one
      pin -- two different commands are a definition conflict.
    '';
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          command = lib.mkOption {
            type = lib.types.str;
            description = "Absolute path of the program to exec (no arguments).";
          };
          greeterOnly = lib.mkOption {
            type = lib.types.bool;
            description = ''
              Pin only the shell greetd starts (a desktop, whose own login
              shells must not re-enter it), or every shell that reads
              /etc/profile (a kiosk, whose login shell is the launcher).
            '';
          };
        };
      }
    );
  };

  config = lib.mkIf (pins != { }) {
    environment.etc.profile.text = lib.mkBefore ''
      # Pinned accounts get their session, whatever was asked for
      # (features/core/users/session-pin.nix).
      case "$(${pkgs.coreutils}/bin/id -u)" in
        ${lib.concatMapStrings caseLine names}
      esac
    '';

    assertions = [
      {
        assertion = (config.services.greetd.settings.general.source_profile or true) != false;
        message = "pinned accounts (${lib.concatStringsSep ", " names}) are pinned through /etc/profile, which greetd only sources with general.source_profile = true.";
      }
    ]
    ++ lib.concatMap (n: [
      {
        assertion = uidOf n != null;
        message = "my.users.${n}: a pinned session needs a pinned uid (the /etc/profile pin matches on it).";
      }
      {
        assertion = !pins.${n}.greeterOnly || config.services.greetd.enable;
        message = "my.users.${n}: the session pin applies to greetd's logins; with greetd off nothing pins it.";
      }
    ]) names;
  };
}
