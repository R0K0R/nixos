{ pkgs }:

{
  system = with pkgs; [
    galaxy-buds-client
    rquickshare
  ];
}
