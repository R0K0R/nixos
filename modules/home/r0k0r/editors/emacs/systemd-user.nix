{ ... }:

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
    startWithUserSession = "graphical";
  };
}
