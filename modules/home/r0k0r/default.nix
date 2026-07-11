{ ... }:

{
  imports = [
    ./imports/third-party.nix
    ./core/account.nix
    ./packages
    ./wayland/niri.nix
    ./wayland/hyprland.nix
    ./i18n/fcitx.nix
    ./ssh/default.nix
    ./editors/opencode.nix
    ./editors/emacs/packages.nix
    ./editors/emacs/doom-config.nix
    ./editors/emacs/systemd-user.nix
    ./editors/emacs/activation.nix
    ./terminals/starship.nix
    ./terminals/fish.nix
    ./terminals/kitty.nix
    ./gui/dms/dank-material-shell.nix
    ./gui/dms/session-lock-hooks.nix
  ];
}
