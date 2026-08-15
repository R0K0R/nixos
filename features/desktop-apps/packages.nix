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
    kdePackages.kdeconnect-kde
    kdePackages.qt6ct
    kdePackages.breeze-icons
    adwaita-icon-theme
    bibata-cursors
  ];
}
