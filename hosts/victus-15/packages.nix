{ pkgs, inputs, ... }:

let
  up = import ../../modules/nixos/packages/user-packages.nix { inherit pkgs; };
  commonComplexPkgs = import ../../modules/nixos/packages/common.nix { inherit pkgs inputs; };
in
{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = up.system.common ++ up.system."victus-15" ++ commonComplexPkgs;
}
