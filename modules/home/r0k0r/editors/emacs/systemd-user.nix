{
  pkgs,
  inputs,
  lib,
  ...
}:

let
  emacsEnv = import ./env.nix { inherit pkgs inputs; };
  inherit (emacsEnv) emacsRolling;
  emacsBin = lib.getExe emacsRolling;
  emacsclientBin = lib.getExe' emacsRolling "emacsclient";
in
{
  /*
    User systemd unit → install with `home-manager switch`, then e.g.
      systemctl --user status emacs.service

    `--fg-daemon` keeps the daemon in the foreground so systemd can supervise it.
    Plain `emacs --daemon` forks and exits immediately (wrong for Type=simple).
  */
  systemd.user.services.emacs = {
    Unit = {
      Description = "Emacs user daemon (Doom)";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };

    Service = {
      Type = "simple";
      ExecStart = "${emacsBin} --fg-daemon";
      # Leading "-" ignores failure when daemon already stopped.
      ExecStop = "-${emacsclientBin} -q --eval \"(kill-emacs)\"";
      Restart = "on-failure";
      RestartSec = "3";
      Slice = "session.slice";
    };

    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
