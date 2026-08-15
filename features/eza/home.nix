{ lib, pkgs, osConfig, ... }:

lib.mkIf osConfig.my.eza.enable {
  home.packages = (import ./packages.nix { inherit pkgs; }).home;
}
