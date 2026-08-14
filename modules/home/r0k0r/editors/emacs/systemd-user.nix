{ hostName, ... }:

{
  /*
    programs.doom-emacs (doom-config.nix) wires services.emacs.package to its
    built emacsWithDoom automatically once provideEmacs is left at its
    default (true) -- this just needs to be turned on. home-manager's own
    unit (Type=notify, SuccessExitStatus=15, login-shell ExecStart) replaces
    the hand-rolled one this file used to define.
  */
  services.emacs = {
    enable = true;

    /*
      "graphical" binds the unit to graphical-session.target, which only ever
      gets started by a compositor. victus-15 is headless (no display manager,
      no compositor), so there the daemon must hang off default.target instead
      or it would simply never start -- and it is reached with
      `emacsclient -nw` over ssh, where that is what you want anyway.
    */
    startWithUserSession = if hostName == "victus-15" then true else "graphical";
  };
}
