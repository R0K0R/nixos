{ config, lib, pkgs, ... }:

let
  cfg = config.my.ccache;
  b = cfg.builder;
  l1 = "${cfg.cacheDir}/l1";
  stage = "${cfg.cacheDir}/stage";
  peerDir = p: "${cfg.cacheDir}/peer-${p.name}";

  /*
    ccache's runtime config for a BUILDER, read per invocation from
    $CCACHE_DIR/ccache.conf. This file is the L2 lever: the derivation side
    never mentions remote storage (env is ccache's highest-precedence source and
    would bake the choice into every hash), so switching L2 on/off/read-only is
    an edit here, live on the next compile, no rebuild.

    Write-behind, measured 2026-09-07: writes go to the LOCAL stage only
    (~7 ms/TU with direct_mode=false vs +0..11 s of WiFi-bound sshfs writes per
    small package when the remote was writable); the read-only PEER probe cost
    nothing measurable (no-peer == with-peer). A resume on the other builder was
    served from the peer at 10.6 s vs 16-21 s to recompile.

    direct_mode=false halves stage traffic by dropping per-TU manifests and
    measured no hit penalty at small-TU size. update-mtime keeps trimming
    (below) from evicting entries the peer is actively reading.
  */
  builderConf = pkgs.writeText "ccache.conf" ''
    max_size = ${cfg.maxSize}
    direct_mode = false
${lib.optionalString cfg.crossDerivation.enable ''
    # The include paths themselves must stop mattering too: the patch handles
    # them inside the preprocessed output, this handles them on the command
    # line. Sound only because direct_mode is off, so what gets hashed is the
    # preprocessed text -- which already encodes the resolved header content.
    ignore_options = -I* -isystem* -idirafter* -iquote*
''}    remote_storage = file:${stage}${lib.concatMapStrings (p: " file:${peerDir p}|read-only=true|update-mtime=true") (lib.attrValues b.peers)}
  '';

  peerType = lib.types.submodule ({ name, ... }: {
    options = {
      name = lib.mkOption { type = lib.types.str; default = name; };
      host = lib.mkOption { type = lib.types.str; description = "Address of the peer builder. Tailscale addresses are the default path here (direct WireGuard on this LAN, measured yulee<->victus 4.4 ms; a DERP fallback would multiply every per-op cost -- check `tailscale ping`)."; };
      user = lib.mkOption { type = lib.types.str; default = "r0k0r"; };
      stage = lib.mkOption { type = lib.types.str; default = "/var/cache/ccache/stage"; description = "The peer's write-behind stage directory, mounted here read-only."; };
    };
  });
in
{
  options.my.ccache = {
    enable = lib.mkEnableOption "ccache for the packages in my.tuning.heavy (client half: the compiler wrapper's config)";

    cacheDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/ccache";
      description = "Root of L1 (l1/), the write-behind stage (stage/) and peer mounts (peer-*/). Must be the same on every builder: it is baked into the wrapper as CCACHE_DIR.";
    };

    crossDerivation = {
      enable = lib.mkEnableOption ''
        cross-derivation reuse: a patched ccache that elides the store hash from
        include paths in line markers, plus a per-package random seed.

        Without it ccache only ever helps on rebuilds of the SAME derivation
        inputs -- an interrupted build, the other builder, a GC, a --check.
        With it, a dependency rebuilt to different bytes but identical headers
        no longer forces its dependents to recompile, which is the common case
        under toolchain and flag churn.

        Validated 2026-09-09 before implementing: the same source preprocessed
        against two zlib-dev paths with byte-identical headers differs on 158
        lines, every one a line marker, and hashes identically once those are
        normalised. See features/ccache/nix-store-normalize.patch for why the
        rewrite must be narrow -- a blanket one collides packages that embed
        their own $out in a string literal
      '';
    };

    maxSize = lib.mkOption {
      type = lib.types.str;
      default = "40G";
      description = "max_size for L1, written to the builder's ccache.conf (not the derivation env, so it is a runtime lever). nixpkgs' programs.ccache never sets this; ccache's 5 GiB default thrashes on webkit-scale objects.";
    };

    wrapperConfig = lib.mkOption {
      type = lib.types.lines;
      readOnly = true;
      internal = true;
      description = "extraConfig handed to ccacheWrapper by tuning/overlays/heavy.nix.";
    };

    builder = {
      enable = lib.mkEnableOption "the builder half: cache dirs, ccache.conf, sandbox path, peer mounts, trimming (NixOS builders only; yulee is Ubuntu, see yulee.md)";

      peers = lib.mkOption {
        type = lib.types.attrsOf peerType;
        default = { };
        description = "Other builders whose stage this machine mounts read-only, so a build interrupted there resumes warm here.";
      };

      identityFile = lib.mkOption {
        type = lib.types.str;
        default = "/run/agenix/remote-builder-ssh-key";
        description = "ssh identity root uses to mount the peers' stages. Default reuses the remote-builder key -- the peers already authorize it.";
      };

      stageMaxSize = lib.mkOption {
        type = lib.types.str;
        default = "40G";
        description = "Trim target for the stage. ccache never cleans remote storage itself (manual: `ccache --trim-dir`), so a timer does.";
      };
    };
  };

  config = lib.mkMerge [
    {
      /*
        What goes into every ccache'd derivation, and nothing more. UMASK=002,
        not the NixOS module's 007: the ten nixbld users share one cache, and
        007 also made stats unreadable to anyone outside the group -- which
        produced convincing zeros during measurement. SLOPPINESS=random_seed
        because nixpkgs passes -frandom-seed=<outhash> per derivation.
      */
      my.ccache.wrapperConfig = ''
        export CCACHE_DIR=${l1}
        export CCACHE_COMPRESS=1
        export CCACHE_SLOPPINESS=random_seed
        export CCACHE_UMASK=002
${lib.optionalString cfg.crossDerivation.enable "        export CCACHE_NIX_STORE_NORMALIZE=1\n"}        # Degrade, don't die: a builder without the cache dir in its sandbox
        # (not yet switched to this config; yulee before yulee.md is done)
        # compiles uncached instead of failing every C/C++ derivation --
        # otherwise the first switch that enables this can never evaluate,
        # since the doom IFD closure already contains ccache'd packages.
        # nixpkgs' programs.ccache exits 1 here; we warn once per build.
        if ! [ -d "$CCACHE_DIR" ] || ! [ -w "$CCACHE_DIR" ]; then
          if [ -n "$NIX_BUILD_TOP" ] && ! [ -e "$NIX_BUILD_TOP/.ccache-disabled" ]; then
            echo "ccache: $CCACHE_DIR is not writable in this sandbox; building without ccache" >&2
            : > "$NIX_BUILD_TOP/.ccache-disabled" 2>/dev/null || true
          fi
          export CCACHE_DISABLE=1
        fi
      '';
    }

    (lib.mkIf b.enable {
      assertions = [
        {
          assertion = b.peers == { } || b.identityFile != "/run/agenix/remote-builder-ssh-key" || config.my.agenix.enable;
          message = "my.ccache.builder mounts peers with the agenix remote-builder key; enable my.agenix or set identityFile.";
        }
      ];

      # The key the peer mounts authenticate with. secrets.nix must list this
      # host among the file's recipients (rekeyed 2026-09-07 to add victus15).
      age.secrets.remote-builder-ssh-key = lib.mkIf (b.peers != { } && b.identityFile == "/run/agenix/remote-builder-ssh-key") {
        file = ../../age/remote-builder-ssh-key.age;
        owner = "root";
        mode = "0400";
      };

      /*
        Group-writable by the build users, world-readable so stats and trimming
        work from outside the group. The ccache.conf is a symlink into the
        store: declarative, and visible inside the sandbox because the store is.
      */
      systemd.tmpfiles.rules = [
        "d ${cfg.cacheDir} 2775 root nixbld -"
        "d ${l1}           2775 root nixbld -"
        "d ${stage}        2775 root nixbld -"
        /*
          COPIED, not symlinked into the store. A build sandbox's /nix/store
          holds only that derivation's own inputs, and this file is nobody's
          input, so a store symlink DANGLES inside the sandbox: ccache cannot
          read it, silently falls back to its defaults, and you get direct_mode
          on, no remote storage and a 5 GiB cache while `ccache --show-config`
          from a login shell shows the intended settings.

          Measured on victus-15: 3240 Direct hits recorded, which direct_mode =
          false makes impossible, and no remote-storage section at all, while
          yulee -- whose conf was written by hand as a regular file -- had the
          config applied and a populated stage.

          C+ overwrites on each activation, so this file is the module's to own;
          a runtime edit is an experiment that lasts until the next switch.
        */
        "C+ ${l1}/ccache.conf 0664 root nixbld - ${builderConf}"
      ] ++ map (p: "d ${peerDir p} 0755 root root -") (lib.attrValues b.peers);

      /*
        PARENT ONLY. Listing a FUSE mountpoint itself here makes the daemon stat
        it during sandbox setup and fail with "Permission denied" (root can read
        it fine; measured). With only the parent listed, Nix binds it
        recursively and the peer submounts ride along.
      */
      nix.settings.extra-sandbox-paths = [ cfg.cacheDir ];

      # sshfs must be findable by mount(8) for fstab-style fuse.sshfs entries.
      system.fsPackages = lib.mkIf (b.peers != { }) [ pkgs.sshfs ];

      /*
        Root mount, not a user session mount: allow_other alone was not enough
        for the daemon's stat, a root mount was. `ro` at the mount and
        read-only=true at the ccache layer both -- belt and braces, since a
        write to a peer's stage would be a cross-machine write we specifically
        measured as the expensive path. automount alone (no nofail: util-linux
        2.39 hands nofail to mount.fuse3, which rejects it; automount already
        never blocks boot and mount-timeout bounds the wait): a peer being down
        must never block this builder; ccache tolerates an absent backend.
      */
      fileSystems = lib.mapAttrs' (n: p: lib.nameValuePair (peerDir p) {
        device = "${p.user}@${p.host}:${p.stage}";
        fsType = "fuse.sshfs";
        options = [
          "ro" "allow_other" "reconnect" "ServerAliveInterval=15" "ServerAliveCountMax=3"
          "IdentityFile=${b.identityFile}" "StrictHostKeyChecking=accept-new"
          "_netdev" "x-systemd.automount" "x-systemd.idle-timeout=600" "x-systemd.mount-timeout=20s"
        ];
      }) b.peers;

      systemd.services.ccache-trim-stage = {
        description = "Trim the ccache write-behind stage to ${b.stageMaxSize}";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.ccache}/bin/ccache --trim-dir ${stage} --trim-max-size ${b.stageMaxSize} --trim-method mtime";
        };
      };
      systemd.timers.ccache-trim-stage = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = "daily"; Persistent = true; RandomizedDelaySec = "1h"; };
      };
    })
  ];
}
