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

  # `config` stays the HOST config (primaryUser below); the peer is args.config.
  peerModule = { name, ... }@args: let p = args.config; in {
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
        default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
        description = ''
          SSH user on the peer for the HUMAN's store operations: the wrappers'
          `nix flake archive --to`, evaluation over ssh, copying derivations
          back. Needs no trust there -- sources and .drv files are
          content-addressed, which a daemon accepts from untrusted clients.
        '';
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = name;
        defaultText = lib.literalExpression "the attribute name";
        description = ''
          What to actually connect to, when that differs from the peer's name.

          Set ONLY in the peer's ssh_config block (peer-*.nix). Everything else
          -- /etc/nix/machines, the substituter URLs, the wrapper scripts --
          keeps using the attribute name, and ssh translates it via
          `Host <name>` / `HostName <address>`. One place knows the address.

          Needed because MagicDNS does not give every client the same name for
          the same machine. A client inside the peer's own tailnet resolves the
          bare name; a client in another tailnet sees the peer as a SHARED
          node, which gets only its FQDN (`<name>.<tailnet>.ts.net`) -- the
          bare name does not resolve there at all.

          Whatever this is set to is what ssh verifies against known_hosts (no
          HostKeyAlias is set), so the peer's knownHosts entry lists it too.
        '';
      };

      daemonUser = lib.mkOption {
        type = lib.types.str;
        default = p.sshUser;
        defaultText = lib.literalExpression "sshUser";
        description = ''
          SSH user the DAEMON logs in as: /etc/nix/machines, the ssh-ng
          substituter, the wrappers' pinned builder. Building input-addressed
          derivations over ssh-ng needs a TRUSTED user on the peer, and people
          are not trusted (registry: nix = "untrusted"), so a NixOS peer
          serves a dedicated "nix-ssh" account (my.remote-builder.server)
          whose forced command is the peer's own nix-daemon. Unmanaged peers
          (yulee) keep whatever their own nix.conf trusts.
        '';
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
        default = [ "benchmark" "big-parallel" "kvm" "nixos-test" "ca-derivations" ];
        description = "system-features the peer advertises, for the generated wrapper scripts.";
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

  /*
    The other side: this host as a peer other hosts' daemons build on. Upstream
    nix.sshServe -- a "nix-ssh" system account whose ForceCommand is
    ${nix.package}/bin/nix-daemon --stdio (THIS host's Nix, not whatever is on
    a login PATH), trusted, authorized for the builder key only. Clients name
    it as the peer's daemonUser.
  */
  options.my.remote-builder.server = {
    enable = lib.mkEnableOption ''
      this host as a remote builder: a trusted "nix-ssh" account for the client
      daemons' builder key (nix.sshServe, ssh-ng, write)
    '';

    extraKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "ssh-ed25519 AAAA... root@some-client" ];
      description = ''
        Further public keys that may log in as the nix-ssh account, besides
        the shared builder key in ./nix-remote-builder.pub. For a client host
        with a builder key of its own (sshKeySecret = null, hand-installed):
        two clients, two credentials, so revoking one does not lock the other
        out. Each key is a trusted-user credential on this host -- the same
        weight as the shared one.
      '';
    };
  };

  options.my.remote-builder.client = {
    enable = lib.mkEnableOption ''
      this host as a remote-build CLIENT: distributed builds, the builder SSH
      key, and the configured peers
    '';

    wrappers.enable = lib.mkEnableOption ''
      generated `nixos-rebuild-<peer>` / `nix-shell-<peer>` scripts, plus
      `-local` variants. Generated from this host's own name, so a cloned host
      rebuilds itself rather than the machine it was copied from.

      A PARKED peer still gets a wrapper. Parking only removes it from
      /etc/nix/machines; the wrapper names that peer as the sole builder and
      substituter, so running it is how you check whether the machine is back,
      and it fails fast against that one host rather than hanging on a mixed
      list
    '';

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/r0k0r/flakes/nixos";
      description = "Flake path baked into the generated wrapper scripts.";
    };

    sshKeySecret = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../age/remote-builder-ssh-key.age";
      description = ''
        agenix-encrypted private key, decrypted at activation instead of
        provisioned by hand into /etc/nix/remote-builder/.

        Null keeps the hand-installed file and its tmpfiles permission rule,
        which is the fallback worth keeping: this key is what DISPATCHES
        remote builds, and on a host with max-jobs = 0 a broken key costs the
        very rebuild that would fix it. Reverting is setting this back to null
        -- or booting the previous generation, which still carries the old
        path.

        Requires my.agenix.enable; features/_meta asserts it.
      '';
    };

    sshKey = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.sshKeySecret != null then
          "/run/agenix/remote-builder-ssh-key"
        else
          "/etc/nix/remote-builder/ssh_key";
      defaultText = lib.literalExpression ''
        "/run/agenix/remote-builder-ssh-key" when sshKeySecret is set,
        otherwise "/etc/nix/remote-builder/ssh_key"
      '';
      description = ''
        Private key the DAEMON (root) uses to reach every peer: in
        /etc/nix/machines and in peer-*.nix's root-only ssh_config match.
        Read at connect time from outside the store. Root-only: on a NixOS
        peer it logs in as the trusted nix-ssh account. People ssh with
        their own keys (my.ssh.identityFile, registry sshKeys).
      '';
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

    evalWorker = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "victus-15";
      description = ''
        The machine that EVALUATES this host's system when rebuilding through it: a
        peer name, or null for this machine. `nixos-rebuild-<evalWorker>` copies the
        flake there, evaluates and builds on it, copies the result back and activates
        it, falling back to evaluating here when the peer can't be reached (see
        wrappers.nix). Every other `nixos-rebuild-<peer>` keeps evaluating here.

        Evaluation is single-threaded and this host's IntraISACross closure is ~22k
        derivations: ~19 s on victus-15 against ~39-72 s on the laptop depending on
        its power profile (measured 2026-10-08, identical .drv).
      '';
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

  config = lib.mkMerge [
  (lib.mkIf config.my.remote-builder.server.enable {
    nix.sshServe = {
      enable = true;
      protocol = "ssh-ng";
      write = true;
      trusted = true;
      keys = [ (lib.fileContents ./nix-remote-builder.pub) ] ++ config.my.remote-builder.server.extraKeys;
    };
    # trusted = true adds nix-ssh to trusted-users itself. Not a person, so
    # not in the registry, and the nix-access assertion does not cover it.
  })
  (lib.mkIf cfg.enable {
    nix.distributedBuilds = true;

    /*
      ROOT-ONLY. This key is what a NixOS peer trusts (its nix-ssh account,
      my.remote-builder.server), so whoever can read it is a trusted user
      there. It used to be readable by r0k0r for interactive `ssh <peer>`;
      people now ssh with their own keys (registry/users/<name>.nix sshKeys).
      Only for the hand-installed key: agenix sets owner/group/mode itself, and
      a `z` rule against /run/agenix would either race the activation script or
      fail outright on a path that does not exist yet.
    */
    systemd.tmpfiles.rules = lib.optionals (cfg.sshKeySecret == null) [
      "z ${cfg.sshKey} 0400 root root -"
    ];

    age.secrets = lib.mkIf (cfg.sshKeySecret != null) {
      "remote-builder-ssh-key" = {
        file = cfg.sshKeySecret;
        # Root-only, see the tmpfiles rule above.
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };


    my.internal.features."remote-builder.agenix" = {
      requires = [ "agenix" ];
      enabledBy = cfg.sshKeySecret != null;
    };

    nix.buildMachines = lib.mapAttrsToList (name: p: {
      hostName = name;
      systems = [ "x86_64-linux" "i686-linux" ];
      /*
        ssh-ng, not ssh. The legacy `ssh://` transport is LegacySSHStore, which
        has no `queryRealisation` operation, and content-addressed derivations
        need exactly that to resolve an output. Dispatching a CA build to an
        `ssh://` builder does not fail cleanly either -- Nix aborts with
        "operation 'queryRealisation' is not supported by store" and a SIGABRT
        stack trace (measured 2026-09-07, nix 2.34.8).

        ssh-ng speaks the daemon protocol over ssh, so the peer's own daemon
        settings apply and the connecting user must be trusted there -- hence
        daemonUser: nix-ssh on a NixOS peer (my.remote-builder.server), r0k0r
        on yulee, whose hand-written nix.conf trusts him.
      */
      protocol = "ssh-ng";
      inherit (p) maxJobs speedFactor;
      sshUser = p.daemonUser;
      sshKey = cfg.sshKey;
      /*
        The peer's OWN declared capability list, not a list derived from this
        machine's system-features.

        This used to take the local system-features, drop the galaxybook-*
        entries, and append "gccarch-meteorlake" unconditionally -- asserting
        that EVERY peer can execute meteorlake code. `features` was already a
        per-peer option, but only wrappers.nix read it, so the host file could
        state a peer's capabilities and be silently overruled here.

        The claim was false for victus-15 (Zen 3), and nothing needed it to
        be true. buildPlatform.canExecute hostPlatform is FALSE under
        IntraISACross -- build and host share a config string but differ in
        gcc.arch -- so nixpkgs takes build-time tools from the untuned
        pkgsBuildBuild set and never asks a peer to execute meteorlake code.
        A peer only COMPILES it, which any x86_64 can do.

        Where tuned code does get run on a peer, the feature flag is not what
        would have saved you: rusty-v8's mksnapshot SIGILLed (return code -4)
        because V8's vendored GN build applies host -march to a build-time
        tool it then executes, entirely inside the package and invisible to
        nixpkgs' cross machinery. That is fixed in the package, not by
        requiring every builder to be an Intel CPU.
      */
      supportedFeatures = p.features;
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
      # No trusted-substituters needed for untrusted users: the daemon lets them
      # pick any entry of this list too, so narrowing it to cache.nixos.org
      # (keeping a dead peer out of an eval) still works.
    };
  })
  ];
}
