{ pkgs, hostName, ... }:

let
  hostFile = ./hosts/${hostName}.nix;
  hostPkgs = if builtins.pathExists hostFile then import hostFile { inherit pkgs; } else [ ];
in
{
  home.packages = (import ./common.nix { inherit pkgs; }) ++ hostPkgs;
}
