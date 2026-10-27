# GUI applications. The icon and cursor themes they resolve against, qt6ct, the
# MTP udev rule and the rnote fixes are the system's half of desktop-apps:
# guests' sessions, the greeter and other homes use those too.
{ pkgs }:
{
  home = with pkgs; [
    libreoffice-qt-stable
    rnote
    google-chrome
    discord
    zoom-us
    poppler-utils
    kdePackages.dolphin
  ];
}
