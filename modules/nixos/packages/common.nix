{ pkgs, inputs, ... }:

with pkgs; [
  wget
  openvpn
  upower

  # Pinned claude-code from the dedicated nixpkgs-claude input (see flake.nix).
  # Replaces the old npm-install-at-activation approach: this one is pinned in
  # flake.lock, rolls back with system generations, and needs no network at
  # activation time. Unfree, so hydra never caches it -- but it's a trivial
  # npm-tarball repack (seconds to build), and the separate input keeps its
  # hash stable across fork/overlay churn. Trade-off: the version is nixpkgs'
  # packaging (typically a few days behind npm latest); bump with
  # `nix flake update nixpkgs-claude`.
  (import inputs.nixpkgs-claude {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  }).claude-code
]
