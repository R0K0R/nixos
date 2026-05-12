{ ... }:

{
  imports = [
    ./imports/third-party.nix
    ./core/account.nix
    ./wayland/niri.nix
    ./i18n/fcitx.nix
    ./ssh/default.nix
    ./editors/emacs/packages.nix
    ./editors/emacs/doom-config.nix
    ./editors/emacs/activation.nix
    ./terminals/starship.nix
    ./terminals/fish.nix
    ./terminals/kitty.nix
    ./gui/dms/dank-material-shell.nix
  ];
}
