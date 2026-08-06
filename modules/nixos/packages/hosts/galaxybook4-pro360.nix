{ pkgs, inputs, ... }:

with pkgs;
[
  # claude-desktop, hash-pinned via the claude-desktop-bin flake input (see
  # flake.nix). Bump: modules/nixos/packages/claude-desktop/update.sh
  # [version], then rebuild.
  (callPackage ../claude-desktop/package.nix { src = inputs.claude-desktop-bin; })

  (writeScriptBin "nixos-rebuild-local" ''
    #! /bin/sh
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --builders "" \
      --option max-jobs 4 \
      --option cores 6 \
      --option substituters "https://cache.nixos.org" \
      "$@"
  '')

  (writeScriptBin "nixos-rebuild-yulee" ''
    #! /bin/sh
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --option max-jobs 0 \
      --builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 7 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

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

  (writeScriptBin "nixos-rebuild-victus-15" ''
    #! /bin/sh
    # No substituters override: cache.nixos.org used to be useless here because
    # the fork patched setup.sh and the cc/bintools wrappers unconditionally, so
    # every hash in the tree diverged from upstream -- even plain native `hello`
    # was absent from the binary cache. Those changes are now confined to the
    # stdenvs that need them, so BUILD-platform derivations are byte-identical
    # to upstream again and the cache genuinely serves them. Leaving the system
    # substituter list alone keeps cache.nixos.org in play; overriding it here
    # would forfeit that.
    # maxJobs 3 (third field after the key): 5 parallel builds drove victus
    # deep into swap -- LTO link steps in particular are memory-hungry.
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --option max-jobs 0 \
      --builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 5 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      "$@"
  '')

  (writeScriptBin "nix-shell-local" ''
    #! /bin/sh
    exec nix-shell \
      --option builders "" \
      --option max-jobs 4 \
      --option cores 6 \
      --option substituters "https://cache.nixos.org" \
      "$@"
  '')

  (writeScriptBin "nix-shell-yulee" ''
    #! /bin/sh
    exec nix-shell \
      --option max-jobs 0 \
      --option builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 7 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

  (writeScriptBin "nix-shell-victus-15" ''
    #! /bin/sh
    exec nix-shell \
      --option max-jobs 0 \
      --option builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 5 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@victus-15" \
      "$@"
  '')

  buildPackages.kdePackages.qtdeclarative.dev

  (writeShellScriptBin "qmlls" ''
    exec ${buildPackages.kdePackages.qtdeclarative}/bin/qmlls "$@"
  '')

  (kdePackages.kdenlive.overrideAttrs (prev: {
    nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
    postInstall = (prev.postInstall or "") + ''
      wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
    '';
  }))
]
