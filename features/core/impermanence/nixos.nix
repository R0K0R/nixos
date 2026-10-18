/*
  An ephemeral root: / is rolled back to an empty snapshot at every boot, and
  only what is declared survives. Design: ~/.cache/home-classify/HANDOFF.md
  §5.6 (agreed 2026-09/10) and docs/multiuser-design.md ("Impermanence").
  Migration of a flat btrfs to this layout: docs/impermanence-migration.md.

  ROOT. btrfs rollback, not tmpfs. In the systemd initrd, before / is
  mounted, @root is moved to old-roots/<timestamp> and recreated as a
  snapshot of @root-blank; old roots are kept `keepPrevious.days` (so a
  file lost to a forgotten persist entry can still be fished out), then
  deleted with their nested subvolumes. Needs my.btrfs-layout (@root,
  @persist).

  WHAT SURVIVES, all under persistRoot (default /persist):
    system   environment.persistence (nix-community/impermanence): `system`
             defaults below + every feature's my.state.system.<class> for the
             classes enabled in `classes`.
    users    per user, merged at BOOT by persist-home-<user>.service:
               - the user's OWN list: their home repo sets the home option
                 my.persist (lib/home-persist.nix), and their home activation
                 writes it to <persistRoot>/home/<user>/.persist.json -- the
                 system cannot evaluate a user's repo, so it reads the list
                 they last activated;
               - my.state.user.<class> from features (eval-time, every user
                 the feature is in scope for is not tracked: it applies to
                 every impermanent user -- feature home halves are per user
                 already, and an entry for an app a user does not run just
                 persists an empty directory);
               - always: .local/state/nix and .local/state/home-manager (the
                 standalone home's profile and generations).
             Each entry is bind-mounted from <persistRoot>/home/<user>/<path>
             to <home>/<path>, before any login. Then the user's current
             home-manager generation is re-activated (hm-reactivate-<user>):
             its dotfile links lived in the wiped home.
             A user whose registry home axis is "persistent" on this host keeps
             the WHOLE home: <persistRoot>/home/<user> bound to <home>.

  Users are the registry's: home = "impermanent" (lib/registry.nix) sets
  my.users.<n>.impermanentHome on a host whose registry facts declare
  impermanence.
*/
{ config, inputs, lib, pkgs, utils, ... }:

let
  cfg = config.my.impermanence;
  lay = config.my.btrfs-layout;
  hostName = config.networking.hostName;
  facts = config.my.registry.loaded.hosts.features.${hostName} or { };

  users = config.my.users;
  impermanentUsers = lib.filterAttrs (_: u: u.impermanentHome) users;
  homeOf = n: config.users.users.${n}.home;
  uidOf = n: toString config.users.users.${n}.uid;
  groupOf = n: config.users.users.${n}.group;

  state = config.my.state;
  pick = side: kind: lib.unique (lib.concatMap (c: state.${side}.${c}.${kind} or [ ]) cfg.classes);

  systemDefaults = {
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd"
      "/etc/NetworkManager/system-connections"
      "/var/lib/NetworkManager"
      "/var/lib/bluetooth"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
  systemDirs = lib.optionals cfg.system.defaults systemDefaults.directories ++ cfg.system.directories ++ pick "system" "directories";
  systemFiles = lib.optionals cfg.system.defaults systemDefaults.files ++ cfg.system.files ++ pick "system" "files";

  alwaysUser = [
    ".local/state/nix"
    ".local/state/home-manager"
  ];
  userData = pkgs.writeText "impermanence-user-state.json" (
    builtins.toJSON {
      directories = alwaysUser ++ pick "user" "directories";
      files = pick "user" "files";
    }
  );

  b = cfg.root.btrfs;
  rollback = pkgs.writeShellScript "impermanence-rollback" (builtins.readFile ./rollback.sh);
  persistHome = pkgs.writeShellScript "persist-home" ''
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.util-linux pkgs.jq pkgs.gnugrep ]}
    ${builtins.readFile ./persist-home.sh}
  '';
  isPersisted =
    p:
    lib.any (d: p == d || lib.hasPrefix "${d}/" p) systemDirs
    || lib.elem p systemFiles
    || lib.hasPrefix "${cfg.persistRoot}/" p;

  audit = pkgs.writeShellScriptBin "imperm-diff" ''
    # Files on the ephemeral root that the next boot will delete: everything on
    # the root subvolume (-xdev: bind mounts from ${cfg.persistRoot}, /nix and
    # other subvolumes are other mounts and are skipped) outside the paths
    # that are always recreated. Run as root to see everything.
    exec ${pkgs.findutils}/bin/find / -xdev \
      \( -path /tmp -o -path /var/tmp -o -path /var/cache -o -path /root/.cache \
         -o -path /etc/static -o -path /proc -o -path /run \) -prune -o \
      -type f -newer /etc/.impermanence-boot -print 2>/dev/null
  '';
in
{
  imports = [ inputs.feat-impermanence.nixosModule ];

  options.my.state = lib.mkOption {
    type = lib.types.submodule {
      options =
        lib.genAttrs [ "system" "user" ] (
          side:
          lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule {
                options = {
                  directories = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                  files = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                  };
                };
              }
            );
            default = { };
            description =
              if side == "system" then
                "class -> absolute system paths a feature keeps state in (persisted under my.impermanence)."
              else
                "class -> paths relative to a user's home a feature keeps state in.";
          }
        );
    };
    default = { };
    description = ''
      What features keep state in, as plain data -- written by features, read
      only by my.impermanence (like my.internal.features). Classes: "secret"
      (keys, tokens), "state" (data that cannot be rebuilt), "optional" (slow
      to rebuild: caches worth keeping, VM images). A feature copied into a
      config without impermanence still evaluates; nothing reads this then.
    '';
  };

  options.my.impermanence = {
    enable = lib.mkEnableOption ''
      an ephemeral root (btrfs rollback at boot) with declared persistence;
      requires my.btrfs-layout with rootSubvolume and persist, and the
      registry fact features.<host>.impermanence'';

    persistRoot = lib.mkOption {
      type = lib.types.str;
      default = lay.persist.mountPoint;
      defaultText = lib.literalExpression "config.my.btrfs-layout.persist.mountPoint";
      description = "Where persisted state lives.";
    };

    classes = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "secret" "state" "optional" ]);
      default = [ "secret" "state" ];
      description = "Which my.state classes are persisted. Add \"optional\" to keep slow-to-rebuild data.";
    };

    root = {
      method = lib.mkOption {
        type = lib.types.enum [ "btrfs-rollback" ];
        default = "btrfs-rollback";
        description = "How / is wiped. Only btrfs rollback exists (agreed: not tmpfs).";
      };
      btrfs = {
        device = lib.mkOption {
          type = lib.types.str;
          default = lay.device;
          defaultText = lib.literalExpression "config.my.btrfs-layout.device";
          description = "The btrfs filesystem holding the root subvolumes.";
        };
        subvolume = lib.mkOption {
          type = lib.types.str;
          default = lay.rootSubvolume;
          defaultText = lib.literalExpression "config.my.btrfs-layout.rootSubvolume";
          description = "The root subvolume, recreated at every boot.";
        };
        blank = lib.mkOption {
          type = lib.types.str;
          default = "@root-blank";
          description = "The empty read-only snapshot / is reset to.";
        };
        keepPrevious = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Keep previous roots under old-roots/ instead of deleting them at once.";
          };
          days = lib.mkOption {
            type = lib.types.ints.positive;
            default = 14;
            description = "How long previous roots are kept.";
          };
        };
      };
    };

    system = {
      defaults = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Persist the usual: machine-id, logs, /var/lib/{nixos,systemd}, ssh host keys, NetworkManager, bluetooth.";
      };
      directories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Further system directories this host persists.";
      };
      files = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Further system files this host persists.";
      };
    };
  };

  config = lib.mkMerge [
    {
      my.internal.features.impermanence = {
        requires = [ "btrfs-layout" ];
        enabledBy = cfg.enable;
      };
      assertions = [
        {
          assertion = (facts.impermanence or false) == cfg.enable;
          message = ''
            registry/hosts.nix features.${hostName}.impermanence = ${lib.boolToString (facts.impermanence or false)}
            but my.impermanence.enable = ${lib.boolToString cfg.enable}. Fix whichever is wrong.'';
        }
      ];
    }

    (lib.mkIf cfg.enable {
      assertions =
        [
          {
            assertion = lay.rootSubvolume != null && lay.persist.enable;
            message = "my.impermanence needs my.btrfs-layout.rootSubvolume and my.btrfs-layout.persist.enable.";
          }
          {
            assertion = config.fileSystems ? ${cfg.persistRoot} && config.fileSystems.${cfg.persistRoot}.neededForBoot;
            message = "my.impermanence: ${cfg.persistRoot} must be a filesystem mounted with neededForBoot.";
          }
          {
            assertion = config.boot.initrd.systemd.enable;
            message = "my.impermanence: the rollback is a systemd-initrd service; set boot.initrd.systemd.enable.";
          }
          {
            # agenix decrypts at activation with these keys: a key on the
            # wiped root is gone after the first reboot, and every secret with it.
            assertion = !(config.my.agenix.enable or false) || lib.all isPersisted config.age.identityPaths;
            message = "my.impermanence: every age.identityPaths entry must be persisted (or under ${cfg.persistRoot}): ${toString config.age.identityPaths}";
          }
          {
            assertion =
              !(config.my.swapfile.enable or false)
              || lib.hasPrefix "/swap/" config.my.swapfile.path
              || lib.hasPrefix "${cfg.persistRoot}/" config.my.swapfile.path;
            message = "my.impermanence: the swapfile (${config.my.swapfile.path}) must not be on the ephemeral root; use /swap/swapfile with my.btrfs-layout.swap.";
          }
        ]
        ++ lib.mapAttrsToList (n: u: {
          assertion = u.hashedPasswordFile == null || isPersisted u.hashedPasswordFile || lib.hasPrefix "/run/" u.hashedPasswordFile;
          message = "my.impermanence: ${n}'s hashedPasswordFile ${toString u.hashedPasswordFile} is on the ephemeral root and would be gone after a reboot.";
        }) users
        ++ lib.mapAttrsToList (n: _: {
          assertion = config.users.users.${n}.uid != null;
          message = "my.impermanence: ${n} needs a pinned uid (the persisted home is owned by it).";
        }) users;

      # The rollback, before / is mounted. systemd initrd: after the root
      # device appears, before sysroot.mount.
      boot.initrd.supportedFilesystems = [ "btrfs" ];
      # The script, bash (its interpreter) and its tools: the systemd initrd
      # ships none of them by default.
      boot.initrd.systemd.storePaths = [ rollback pkgs.coreutils pkgs.gnused pkgs.util-linux ];
      boot.initrd.systemd.extraBin = {
        btrfs = "${pkgs.btrfs-progs}/bin/btrfs";
      };
      boot.initrd.systemd.services.impermanence-rollback = {
        description = "Roll / back to ${b.blank}";
        wantedBy = [ "initrd.target" ];
        before = [ "sysroot.mount" ];
        after = [ "${utils.escapeSystemdPath b.device}.device" ];
        requires = [ "${utils.escapeSystemdPath b.device}.device" ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        environment = {
          PATH = lib.makeBinPath [ pkgs.coreutils pkgs.gnused pkgs.util-linux pkgs.btrfs-progs ];
          DEVICE = b.device;
          ROOT = b.subvolume;
          BLANK = b.blank;
          KEEP = if b.keepPrevious.enable then toString b.keepPrevious.days else "0";
        };
        serviceConfig.ExecStart = "${rollback}";
      };

      environment.persistence.${cfg.persistRoot} = {
        hideMounts = true;
        directories = systemDirs;
        files = systemFiles;
      };

      # A marker the audit tool compares against: everything newer was made
      # this boot, on the root that the next boot deletes.
      systemd.tmpfiles.rules =
        [ "f /etc/.impermanence-boot 0644 root root -" ]
        ++ [ "d ${cfg.persistRoot}/home 0755 root root -" ]
        ++ lib.concatMap (n: [ "d ${cfg.persistRoot}/home/${n} 0700 ${n} ${groupOf n} -" ]) (lib.attrNames users);

      environment.systemPackages = [ audit ];

      systemd.services =
        lib.mapAttrs' (
          n: u:
          lib.nameValuePair "persist-home-${n}" {
            description = "Persisted home of ${n}";
            wantedBy = [ "multi-user.target" ];
            # Before anyone can log in, and before ${n}'s user manager.
            before = [ "systemd-user-sessions.service" "user@${uidOf n}.service" ];
            after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
            unitConfig.RequiresMountsFor = [ cfg.persistRoot ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.escapeShellArgs [
                persistHome
                n
                (uidOf n)
                (groupOf n)
                (homeOf n)
                "${cfg.persistRoot}/home/${n}"
                (if u.impermanentHome then "lists" else "whole")
                userData
              ];
            };
          }
        ) users
        // lib.mapAttrs' (
          n: _:
          lib.nameValuePair "hm-reactivate-${n}" {
            description = "Re-activate ${n}'s home-manager generation on the fresh home";
            wantedBy = [ "multi-user.target" ];
            after = [ "persist-home-${n}.service" ];
            requires = [ "persist-home-${n}.service" ];
            before = [ "systemd-user-sessions.service" ];
            unitConfig.ConditionPathExists = "${homeOf n}/.local/state/nix/profiles/home-manager/activate";
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              User = n;
              ExecStart = "${homeOf n}/.local/state/nix/profiles/home-manager/activate";
            };
          }
        ) impermanentUsers
        # An integrated home (activated by the system) must wait for its
        # persisted directories too.
        // lib.mapAttrs' (
          n: _:
          lib.nameValuePair "home-manager-${n}" {
            after = [ "persist-home-${n}.service" ];
            requires = [ "persist-home-${n}.service" ];
          }
        ) (lib.filterAttrs (n: _: config.home-manager.users ? ${n}) users);
    })
  ];
}
