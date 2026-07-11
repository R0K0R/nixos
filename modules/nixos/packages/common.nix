{ pkgs, ... }:

with pkgs; [
  wget
  openvpn
  upower

  # claude-code pinned by ./claude-code/manifest.json, fetched from Anthropic's
  # own release channel (downloads.claude.ai) -- every published version is
  # available there immediately, unlike nixpkgs' packaging cadence. Pinned in
  # git, rolls back with generations, no network needed at activation time.
  # Bump: modules/nixos/packages/claude-code/update.sh [version], then rebuild.
  (callPackage ./claude-code/package.nix { })
]
