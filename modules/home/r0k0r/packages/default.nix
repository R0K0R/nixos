{ pkgs, lib, hostName, inputs, osConfig, ... }:

let
  up = import ../../../nixos/packages/user-packages.nix { inherit pkgs; };

  hostFile = ./hosts/${hostName}.nix;
  hostPkgs = if builtins.pathExists hostFile then import hostFile { inherit pkgs inputs; } else [ ];
in
# Gated so the single home config is safe on a host that wants none of this.
# Collapsing home-r0k0r-headless.nix into home-r0k0r.nix would otherwise have
# handed victus-15 the `homeManager.common` list it never had.
#
# Still keyed by hostname, which is exactly what the packages rework replaces
# with per-feature packages.nix files -- this gate is the interim step, not the
# destination.
lib.mkIf osConfig.my.packages.homeManager.enable {
  home.packages = up.homeManager.common ++ (up.homeManager.${hostName} or [ ]) ++ hostPkgs;
}
