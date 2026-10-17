/*
  Benjamin's own home-manager modules, layered on top of the system flake's
  feature home halves (homeLib.<host>.modules, which mkHome always includes).

  Every module here follows the same shape: it declares its own
  `options.my.<name>.enable` (and whatever else it needs) and does nothing
  until a host turns it on in hosts/<host>.nix. There is no NixOS half to
  read the switch from -- this repo is a home, not a system -- so the home
  module IS the option. `osConfig` is read only for genuine facts about the
  machine (which compositor it runs, its primary output and scale, the
  Hyprland modifier), never for a switch of ours.

    desktop/   the bonfire desktop: Hyprland user config, bonfire shell, flare
               (notification centre), pyre (dock), panelbus, hearth settings,
               lyre (audio engine), tray applets
    editor/    neovim, Emacs (his Doom config)
    shell/     fastfetch greeting, fish extras, kitty look
    apps/      KakaoTalk, Dolphin, the per-user package list, the Storytold
               suite, the Chromium fractional-scale fix, Firefox portal pref

  Arguments available here: pkgs (the HOST's package set), lib, config,
  osConfig, hostName, inputs (the SYSTEM flake's inputs -- its feature halves
  need it), userInputs (THIS repo's inputs).
*/
{ ... }:

{
  imports = [
    ./desktop
    ./editor
    ./shell
    ./apps
  ];
}
