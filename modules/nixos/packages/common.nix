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

  (writeScriptBin "runtime-cache-refresh" ''
    #! /bin/sh
    # Refreshes every runtime-cache tier -- the aliasable-names cache
    # (upstream-tools-overlay.nix's expensive attribute walk, host-independent),
    # Tier 2 (eval heuristic) for both hosts, and Tier 1 (live system closure)
    # for this host only, since that one requires actually being on the
    # target machine. No rebuild. `git add`s the cache dir afterward: these
    # are new,
    # untracked-by-default paths, and a dirty git tree's flake evaluation
    # (what nixos-rebuild actually uses, no --impure) only sees git-tracked
    # files -- an untracked cache file is invisible to it, silently falling
    # through to Tier 3 with zero error. Hit exactly this once already:
    # isHostRuntime "mesa" was already correctly true, but a real rebuild
    # used none of it because the cache files it needed didn't exist as far
    # as the evaluated (tracked-only) tree was concerned.
    set -eu
    CACHE_DIR=/home/r0k0r/flakes/nixos/modules/nixos/nix/runtime-cache

    echo "refreshing aliasable-names cache (host-independent)..."
    "$CACHE_DIR/refresh-aliasable.sh"

    echo "refreshing tier2 cache (both hosts)..."
    "$CACHE_DIR/refresh-tier2.sh" all

    echo "refreshing tier1 cache (this host)..."
    "$CACHE_DIR/refresh-tier1.sh" galaxybook4-pro360

    git -C /home/r0k0r/flakes/nixos add "$CACHE_DIR"
    echo "cache refreshed and staged -- commit modules/nixos/nix/runtime-cache if you want this to persist"
  '')
]
