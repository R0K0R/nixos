# GPU/VA-API and CPU/power inspection tools.
{ pkgs }:
{
  system = with pkgs; [
    libva-utils
    powertop
    s-tui
  ];
}
