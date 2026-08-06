/*
  Complex derivations shared across both hosts -- not plain package
  references, so they don't belong in user-packages.nix (see that file's own
  header). Mirrors modules/nixos/packages/hosts/galaxybook4-pro360.nix's
  same split, just for things common to every host instead of one.
*/
{ pkgs, inputs, ... }:

with pkgs;
[
  # claude-code, hash-pinned via the claude-code-bin flake input (Anthropic's
  # release channel carries every published version immediately -- no nixpkgs
  # packaging lag). Pinned in flake.lock, rolls back with generations, no
  # network needed at activation time.
  # Bump: modules/nixos/packages/claude-code/update.sh [version], then rebuild.
  (callPackage ./claude-code/package.nix { src = inputs.claude-code-bin; })
]
