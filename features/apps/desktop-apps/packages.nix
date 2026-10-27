# The host side of desktop-apps: what GUI programs resolve against, for every
# account and the greeter -- icon and cursor themes, and qt6ct, whose
# platform-theme plugin features/qt-theming loads from the system profile's Qt
# plugin dir.
{ pkgs }:
{
  system = with pkgs; [
    kdePackages.qt6ct
    kdePackages.breeze-icons
    adwaita-icon-theme
    bibata-cursors
  ];
}
