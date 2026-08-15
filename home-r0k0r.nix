{ ... }:

/*
  The single home config for r0k0r, used by every host.

  There used to be a second one (home-r0k0r-headless.nix) because importing the
  full config dragged the whole GUI stack -- niri, hyprland, DMS, kitty, cursor,
  qt theming -- onto a machine with no display to attach it to. That is gone:
  every feature's home half now gates on `osConfig.my.<feature>.enable`, so a
  headless host simply does not switch those on and they cost nothing. The two
  places that genuinely differ (terminal-only Emacs build, daemon on
  default.target) are `my.emacs.headless`, a property of the machine rather than
  a test against its name.

  Feature home modules arrive via home-manager.sharedModules -- see mkHost in
  flake.nix. This file carries only what is not a feature: the account identity
  and the package lists.
*/
{
  imports = [
    ./modules/home/r0k0r
  ];
}
