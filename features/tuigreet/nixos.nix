{ config, lib, pkgs, ... }:

let
  cfg = config.my.tuigreet;
in
{
  options.my.tuigreet.enable = lib.mkEnableOption "tuigreet, the terminal login greeter, as greetd's session";

  config = lib.mkMerge [
    {
      my.internal.features.tuigreet = {
        # A greetd session, the same relationship dms.greeter declares:
        # without greetd it is installed and never launched.
        requires = [ "greetd" ];
        enabledBy = cfg.enable;
      };
    }

    (lib.mkIf cfg.enable {
      /*
        Mutually exclusive with dms.greeter by construction rather than by
        assertion: both define greetd's default_session.command, and enabling
        the two at once fails evaluation with a conflicting-definitions
        error naming both files.
      */
      services.greetd.settings.default_session.command = lib.concatStringsSep " " [
        "${pkgs.tuigreet}/bin/tuigreet"
        "--time"
        # Prefill the last user, and reopen each user's last-used session --
        # so the daily path is: type password, Enter.
        "--remember"
        "--remember-user-session"
        "--asterisks"
        # NixOS has no /usr/share/wayland-sessions for tuigreet to scan; the
        # sessions live in the displayManager's aggregated package
        # (hyprland.desktop comes from programs.hyprland in
        # features/hyprland).
        "--sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions"
      ];

      # --remember persists into /var/cache/tuigreet, which nothing creates
      # for the unprivileged greeter user greetd runs the session as.
      systemd.tmpfiles.rules = [
        "d /var/cache/tuigreet 0755 greeter greeter - -"
      ];
    })
  ];
}
