{ pkgs, ... }:

with pkgs; [
  wget
  openvpn
  upower
  nautilus
  kdePackages.kdeconnect-kde
  kdePackages.qt6ct

  /*
    fcitx5 tray (Classic UI StatusNotifier): requests Icon `input-keyboard-symbolic` (see dbus
    `:…/StatusNotifierItem` IconName). That lives in KDE/GNOME themes, not in hicolor-only trees,
    otherwise QuickShell shows the magenta fallback tile.
  */
  kdePackages.breeze-icons
  adwaita-icon-theme
]
