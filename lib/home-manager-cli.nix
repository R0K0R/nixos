/*
  The system's home-manager CLI: what standalone accounts switch with
  (lib/home-manager.nix puts it in systemPackages) and what hm-switch
  (features/core/epoch) runs. One expression for both, so they are one store
  path rather than two builds of the same script that could drift apart.

  Built from the same home-manager input the generator and homeLib use: a CLI
  from another release would run a different activation than the one the home
  was evaluated against.
*/
{ inputs, pkgs, nix }:

pkgs.callPackage "${inputs.home-manager}/home-manager" {
  path = "${inputs.home-manager}";
  # Its `home-manager option` wraps nixos-option, which puts pkgs.nix on
  # PATH -- 2.34, a second Nix next to the system's nix.package (2.35)
  # and the client/daemon split that broke CA builds before. Same
  # nixos-option, the system's Nix.
  pkgs = pkgs // { nixos-option = pkgs.nixos-option.override { inherit nix; }; };
}
