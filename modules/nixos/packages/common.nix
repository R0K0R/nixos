/*
  Complex derivations shared across both hosts -- not plain package
  references, so they don't belong in user-packages.nix (see that file's own
  header). Mirrors modules/nixos/packages/hosts/galaxybook4-pro360.nix's
  same split, just for things common to every host instead of one.
*/
{ pkgs, inputs, ... }:

with pkgs;
[
  (writeScriptBin "runtime-cache-refresh" ''
    #! /bin/sh
    # Refreshes the runtime-cache for THIS host: the aliasable-names cache
    # (upstream-tools-overlay.nix's expensive attribute walk, host-independent),
    # then Tier 2 (eval heuristic) and Tier 1 (live system closure). Run it on
    # each machine; it does not rebuild anything.
    #
    # `git add` at the end is load-bearing, not tidiness: a dirty tree's flake
    # evaluation -- what nixos-rebuild actually does, without --impure -- only
    # sees files git knows about. A cache file that git cannot see is written
    # successfully, reported as written, and then silently ignored by the
    # rebuild, which falls through to Tier 3 with no error at all. Hit twice:
    # once when the files were new and untracked, and again when they were
    # briefly listed in .gitignore (which also made plain `git add` a no-op).
    # They are deliberately tracked now -- see the note in .gitignore.
    set -eu
    CACHE_DIR=/home/r0k0r/flakes/nixos/modules/nixos/nix/runtime-cache

    echo "refreshing aliasable-names cache (host-independent)..."
    "$CACHE_DIR/refresh-aliasable.sh"

    # Both tiers are for THIS host only.
    #
    # Tier 1 must be: it captures /run/current-system, so a hardcoded name wrote
    # victus-15's 461-package closure into galaxybook4-pro360's cache file when
    # run from victus-15.
    #
    # Tier 2 could technically be computed for any host from anywhere (its eval
    # is a throwaway config for the named host), but each machine has its own
    # checkout of this repo. Refreshing "all" means both machines rewrite each
    # other's cache files and then fight over them in git. Each host owning its
    # own tier1 + tier2 keeps that clean; run this on each machine.
    echo "refreshing tier2 cache (this host: $(hostname))..."
    "$CACHE_DIR/refresh-tier2.sh" "$(hostname)"

    echo "refreshing tier1 cache (this host: $(hostname))..."
    "$CACHE_DIR/refresh-tier1.sh" "$(hostname)"

    git -C /home/r0k0r/flakes/nixos add "$CACHE_DIR"
    echo "cache refreshed and staged -- commit modules/nixos/nix/runtime-cache if you want this to persist"
  '')
]
