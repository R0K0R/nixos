/*
  Offload builds to remote machines via Nix distributed builds.

  After this is active, plain `sudo nixos-rebuild switch` (with /etc/nixos → flake)
  builds on a peer. Nix still uploads missing store paths over SSH (one at a time per
  builder URL) and copies results back for switch — hence builders-use-substitutes.

  One-time bootstrap (before the first switch that installs this module):
    bash ~/flakes/nixos/scripts/bootstrap-yulee-builder-on-laptop.sh
    # then run switch once with --builders (see script output)

  On a peer (/etc/nix/nix.conf):
    max-jobs = 10
    trusted-users = root @wheel r0k0r
    experimental-features = nix-command flakes
    system-features = benchmark big-parallel kvm nixos-test gccarch-meteorlake

  r0k0r must be in group nix-users on the peer. Builder pubkey in authorized_keys
  (see ./nix-remote-builder.pub).
*/
{ config, lib, ... }:

let
  cfg = config.my.remote-builder.client;

  # Parked peers vanish from /etc/nix/machines entirely.
  activePeers = lib.filterAttrs (_: p: p.enable) cfg.peers;

  peerModule = { name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether this peer is currently usable. Set false to PARK a machine
          that is down, without deleting its definition.

          This is not a convenience. nix.conf sets `max-jobs = 0` -- nothing
          builds locally, by design -- and `builders = @/etc/nix/machines`, which
          the DAEMON reads. An unreachable peer in that file is tried first if
          its speedFactor is higher, and hangs in SSH until it times out, for
          every derivation.

          It cannot be worked around with a command-line flag.
          nixos-rebuild-ng composes `flake_eval_flags` from its own argument
          group ONLY (models.py:183), so neither `--builders` nor
          `--option builders` reaches the `nix eval` step -- and that step is
          where import-from-derivation builds happen, which for this config
          means doom-intermediates. The peer list is the only lever.
        '';
      };

      sshUser = lib.mkOption {
        type = lib.types.str;
        default = "r0k0r";
        description = "SSH user on the peer.";
      };
      maxJobs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = ''
          Parallel builds on the peer. Sized to its RAM, not its cores: 5
          parallel builds drove victus-15 deep into swap, LTO link steps in
          particular being memory-hungry.
        '';
      };
      speedFactor = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Relative speed, used by Nix to prefer faster peers.";
      };
      features = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "benchmark" "big-parallel" "kvm" "nixos-test" ];
        description = "system-features the peer advertises, for the generated wrapper scripts.";
      };
      useAsSubstituter = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the generated wrappers override `substituters` to include this
          peer's store.

          False for a peer whose builds are byte-identical to upstream:
          cache.nixos.org used to be useless here because the fork patched
          setup.sh and the cc/bintools wrappers unconditionally, so every hash
          in the tree diverged -- even plain native `hello` was absent from the
          binary cache. Those changes are now confined to the stdenvs that need
          them, so BUILD-platform derivations match upstream again and the cache
          genuinely serves them. Leaving the system substituter list alone keeps
          cache.nixos.org in play; overriding it would forfeit that.
        '';
      };
    };
  };
in
{
  imports = [
    ./peer-yulee.nix
    ./peer-victus-15.nix
    ./wrappers.nix
  ];

  options.my.remote-builder.client = {
    enable = lib.mkEnableOption ''
      this host as a remote-build CLIENT: distributed builds, the builder SSH
      key, and the configured peers
    '';

    wrappers.enable = lib.mkEnableOption ''
      generated `nixos-rebuild-<peer>` / `nix-shell-<peer>` scripts, plus
      `-local` variants. Generated from this host's own name, so a cloned host
      rebuilds itself rather than the machine it was copied from
    '';

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/r0k0r/flakes/nixos";
      description = "Flake path baked into the generated wrapper scripts.";
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/remote-builder/ssh_key";
      description = "Private key used to reach every peer.";
    };

    localJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "max-jobs for the `-local` wrappers.";
    };

    localCores = lib.mkOption {
      type = lib.types.ints.positive;
      default = 6;
      description = "cores for the `-local` wrappers.";
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule peerModule);
      default = { };
      description = "Remote builders, keyed by hostname.";
    };

    substituters = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra substituters (peer stores) for the system nix.settings.";
    };

    trustedPublicKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Public keys for the peer stores listed in `substituters`.";
    };
  };

  config = lib.mkIf cfg.enable {
    nix.distributedBuilds = true;

    # Make the builder SSH key readable by r0k0r so `ssh <peer>` works
    # interactively without a separate key. Group must be `users` -- there is no
    # `r0k0r` group, and systemd-tmpfiles skips the whole line on an
    # unresolvable group ("Failed to resolve group 'r0k0r'"), silently leaving
    # the key root-owned.
    systemd.tmpfiles.rules = [
      "z ${cfg.sshKey} 0600 r0k0r users -"
    ];

    nix.buildMachines = lib.mapAttrsToList (name: p: {
      hostName = name;
      systems = [ "x86_64-linux" "i686-linux" ];
      protocol = "ssh";
      inherit (p) maxJobs speedFactor sshUser;
      sshKey = cfg.sshKey;
      # Bootstrap tools are generic x86-64 (hit cache.nixos.org); only HOST
      # outputs need the tuned arch.
      supportedFeatures = lib.unique (
        lib.filter (f: !(lib.hasPrefix "galaxybook-" f)) config.nix.settings.system-features
        ++ [ "gccarch-meteorlake" ]
      );
    }) activePeers;

    nix.settings = {
      # NixOS emits `builders =` (empty) by default, which disables Nix's built-in
      # default of @/etc/nix/machines. Point at the file buildMachines generates.
      builders = "@/etc/nix/machines";
      builders-use-substitutes = true;
      # Never build locally — delegate everything to the peers.
      max-jobs = 0;
      # Use peer /nix/store as a binary cache — arch-specific builds that miss
      # cache.nixos.org are served from the peer directly.
      substituters = [ "https://cache.nixos.org" ] ++ cfg.substituters;
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      ] ++ cfg.trustedPublicKeys;
    };
  };
}
