{ config, lib, userInputs, ... }:

{
  options.my.ownDoomConfig.enable = lib.mkEnableOption ''
    Benjamin's own Doom config (github:sihooleebd/doom-emacs, the `doom-private` input of this
    repo) in place of the system flake's. The Emacs build, the daemon and Unstraightened's
    pipeline stay the system feature's; only the Doom directory it builds from changes. The
    system's emacs feature must be on for this account (my.emacs.enable and users there)
  '';

  config = lib.mkIf config.my.ownDoomConfig.enable {
    /*
      mkForce, because the system's emacs home half sets doomDir to its own input and two plain
      definitions of one option are an error. Everything else that half derives from doomDir
      (the doom-intermediates and per-package IFD) follows this value, so evaluating this home
      builds Doom's package list from THIS config, not the system's.

      The font (doom-machine-local.el) is NOT set here: it is generated from the SYSTEM option
      my.emacs.font, a host fact -- see README.md, "What the system must provide".
    */
    programs.doom-emacs.doomDir = lib.mkForce userInputs.doom-private;
  };
}
