{ ... }:

/*
  Home config for headless hosts (victus-15): Emacs only.

  Deliberately NOT ./modules/home/r0k0r -- that pulls in the whole GUI stack
  (niri, hyprland, DMS, kitty, cursor, qt theming), none of which has a display
  to attach to on a machine with no display manager or compositor. The Emacs
  modules themselves are shared verbatim with galaxybook4-pro360; the two
  places that must differ (terminal-only Emacs build, and binding the daemon to
  default.target rather than graphical-session.target) branch on `hostName`
  inside those modules.
*/
{
  imports = [
    ./modules/home/r0k0r/core/account.nix
    ./modules/home/r0k0r/editors/emacs/doom-config.nix
    ./modules/home/r0k0r/editors/emacs/systemd-user.nix
  ];
}
