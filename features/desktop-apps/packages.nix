# GUI applications and the icon/theme packages they resolve against.
{ pkgs }:
{
  system = with pkgs; [
    libreoffice
    rnote
    google-chrome
    discord
    zoom-us
    poppler-utils

    kdePackages.dolphin
    # kdeconnect-kde is installed by programs.kdeconnect, enabled from
    # features/network -- listing it here too would install it independently of
    # the firewall ranges it needs, which is how it came to be half-configured.
    kdePackages.qt6ct
    kdePackages.breeze-icons
    adwaita-icon-theme
    bibata-cursors
  ];
}
