{ pkgs, hostName, inputs, ... }:

let
  hostFile = ./hosts/${hostName}.nix;
  hostPkgs = if builtins.pathExists hostFile then import hostFile { inherit pkgs inputs; } else [ ];
in
{
  home.packages = (import ./common.nix { inherit pkgs; }) ++ hostPkgs;
}
