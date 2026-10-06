# Wireless displays: Miracast (Wi-Fi Direct) and Chromecast.
{ pkgs }:
{
  user = with pkgs; [
    gnome-network-displays
  ];
}
