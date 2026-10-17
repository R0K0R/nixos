# The bonfire desktop. Each module is imported unconditionally and gated by its own
# my.<name>.enable, set per host in hosts/<host>.nix.
{ ... }:

{
  imports = [
    ./settings.nix
    ./panelbus.nix
    ./hyprland
    ./bonfire
    ./flare
    ./pyre
    ./lyre.nix
    ./tray-applets.nix
    ./fcitx-tray.nix
  ];
}
