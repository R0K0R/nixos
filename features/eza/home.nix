{ config, lib, pkgs, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.eza.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "eza"; };
in
lib.mkIf (osConfig.my.eza.enable && inScope) {
  home.packages = (import ./packages.nix { inherit pkgs; }).home;
}
