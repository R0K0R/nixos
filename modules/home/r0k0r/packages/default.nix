{ pkgs, hostName, inputs, ... }:

let
  up = import ../../../nixos/packages/user-packages.nix { inherit pkgs; };

  hostFile = ./hosts/${hostName}.nix;
  hostPkgs = if builtins.pathExists hostFile then import hostFile { inherit pkgs inputs; } else [ ];
in
{
  home.packages = up.homeManager.common ++ (up.homeManager.${hostName} or [ ]) ++ hostPkgs;
}
