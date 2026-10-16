# Baseline tools every host wants, regardless of role.
{ pkgs }:
{
  system = with pkgs; [
    wget
    openvpn
    upower
    jq
  ];
}
