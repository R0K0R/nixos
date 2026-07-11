{ pkgs, inputs, ... }:

with pkgs; [
  wget
  openvpn
  upower

  # claude-code, hash-pinned via the claude-code-bin flake input (Anthropic's
  # release channel carries every published version immediately -- no nixpkgs
  # packaging lag). Pinned in flake.lock, rolls back with generations, no
  # network needed at activation time.
  # Bump: modules/nixos/packages/claude-code/update.sh [version], then rebuild.
  (callPackage ./claude-code/package.nix { src = inputs.claude-code-bin; })
]
