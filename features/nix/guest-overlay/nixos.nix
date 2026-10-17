/*
  A private Nix store per guest: registry users with nix = "overlay".

  WHY. Sharing a store is sharing trust. An untrusted user of the shared
  daemon cannot pick builders or substituters, because whatever they return
  would land in the store everyone runs from. A guest here gets a store of
  their own instead -- an OverlayFS of the system's store (lower, read-only)
  and their own objects (upper) -- and owns it: no daemon in between, so every
  setting is theirs, their own builders included, and nothing they build or
  fetch is ever visible outside their sessions.

  HOW, per guest:

    lower   a frozen, read-only btrfs snapshot of /nix (lower-snapshot.sh),
            taken at boot and after every activation. Frozen because OverlayFS
            forbids a lower layer that changes underneath it, and because the
            system's GC deletes paths a guest may still use. Needs /nix to be
            a subvolume: my.btrfs-layout.
    upper   BASE/<user>/upper on the guest's own subvolume (quota: `quota`).
    mount   BASE/.merged/<user>, by nix-guest-overlay-<user>.service, which
            also REBASES onto the newest snapshot when nothing of the guest's
            is running: drops upper copies of paths the lower now has, copies
            up (reflink) paths the lower lost but the guest still references.
    view    pam_namespace (session stacks in `pamServices`) gives each guest
            session its own mount namespace with BASE/.merged/<user> bound
            over /nix/store and BASE/.etc/<user> over /etc/nix -- whose
            nix.conf makes their `nix` open the overlay store directly
            (local-overlay://, check-mount on), as its owner.
    daemon  the shared one refuses them (allowed-users); they never need it.

  ROOT NEVER RUNS ANYTHING FROM A GUEST'S VIEW. Inside the namespace
  /nix/store is partly the guest's, so:
    - no pam_namespace init script: it would run as root AFTER the bind, its
      interpreter resolved through the guest's store;
    - the merged store root is root-owned and sticky, so lower objects cannot
      be renamed or replaced;
    - `wrappers` (default "hidden"): /run/wrappers is an empty nosuid tmpfs
      in guest namespaces. A setuid wrapper execs a store path, and after a
      system switch during a guest session the session's lower snapshot is
      older than the wrappers, so the target can be missing there -- and a
      missing name is one the guest can create. "shared" keeps the system's
      wrappers (screen lockers can check passwords via unix_chkpwd; sudo, ping,
      fusermount work) and accepts that window.

  KNOWN LIMITS. A session keeps the lower it started with: after a system
  switch, paths newer than it (/run/current-system, /etc/static targets) are
  dangling in that session until the guest logs out and back in. A guest's
  lock screen cannot verify a password with wrappers = "hidden". The local
  overlay store is an experimental Nix feature. Never tested on hardware.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.guest-overlay;
  hostName = config.networking.hostName;
  facts = config.my.registry.loaded.hosts.features.${hostName} or { };

  guests = lib.filterAttrs (_: u: u.nix == "overlay") config.my.users;
  names = lib.attrNames guests;
  active = cfg.enable && guests != { };
  uidOf = n: toString config.users.users.${n}.uid;
  groupOf = n: config.users.users.${n}.group;

  base = cfg.stateDir;
  lroot = cfg.lowerDir;

  tools = with pkgs; [
    btrfs-progs
    coreutils
    findutils
    gnugrep
    gnused
    procps
    sqlite
    util-linux
    systemd
  ];
  mkScript = name: file: pkgs.writeShellScript name ''
    export PATH=${lib.makeBinPath tools}
    ${builtins.readFile file}
  '';
  snapshot = mkScript "nix-guest-lower-snapshot" ./lower-snapshot.sh;
  mountOverlay = mkScript "nix-guest-overlay" ./overlay-mount.sh;

  # A store URL inside a store URL: the inner one's ? & = are escaped.
  enc = builtins.replaceStrings [ "%" "?" "&" "=" ] [ "%25" "%3F" "%26" "%3D" ];
  storeUrl =
    n:
    "local-overlay://?lower-store=${enc "local?root=${base}/${n}/lower&read-only=true"}"
    + "&upper-layer=${base}/${n}/upper&state=${base}/${n}/state";

  # The guest's /etc/nix/nix.conf. A real file (tmpfiles C), never a symlink
  # into /etc/static: that would resolve through the guest's lower snapshot,
  # which after a system switch may not have it.
  nixConfText =
    n:
    ''
      # Your own store: an overlay of the system's (read-only) and yours.
      # Settings here and in ~/.config/nix/nix.conf are all yours to change --
      # builders and substituters included; nothing you build or fetch leaves
      # your sessions.
      store = ${storeUrl n}
      experimental-features = nix-command flakes local-overlay-store read-only-local-store
      build-users-group =
      sandbox = true
      substituters = https://cache.nixos.org
      trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
      # This host's policy for its own CPU (registry features.<host>.localBuilds);
      # name your own builders to build anything.
      max-jobs = ${if facts.localBuilds or true then "auto" else "0"}
    '';
  nixConf = n: pkgs.writeText "nix-guest-${n}.conf" (nixConfText n);

  only = "~" + lib.concatStringsSep "," names;
  namespaceConf = ''
    # nix-guest overlay stores (features/nix/guest-overlay). Instance parents are
    # mode 0000, root's; no init script runs (see the feature's header).
    /nix/store ${base}/.merged/ user:noinit ${only}
    /etc/nix ${base}/.etc/ user:noinit ${only}
  ''
  + lib.optionalString (cfg.wrappers == "hidden") ''
    /run/wrappers ${base}/.wrappers/ tmpfs:noinit:mntopts=nosuid,nodev,noexec,size=64k ${only}
  '';
in
{
  options.my.guest-overlay = {
    enable = lib.mkEnableOption ''
      private overlay Nix stores for registry users with nix = "overlay" (and
      the registry fact features.<host>."guest-overlay" must say so too).
      Requires my.btrfs-layout'';

    wrappers = lib.mkOption {
      type = lib.types.enum [ "hidden" "shared" ];
      default = "hidden";
      description = ''
        /run/wrappers in guest sessions. "hidden": an empty nosuid tmpfs -- no
        setuid or setcap program runs inside a guest's namespace (no sudo, su,
        ping, fusermount, and no unix_chkpwd, so a lock screen cannot check
        their password). "shared": the system's wrappers, which root then runs
        from a store view the guest partly controls; see the feature header
        for the window that opens.
      '';
    };

    quota = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "20G";
      description = ''
        btrfs qgroup limit on each guest's subvolume (upper layer + state).
        Setting it turns quotas on for the whole filesystem, which has a
        real cost on btrfs (qgroup accounting on every snapshot and delete).
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nix-guests";
      description = "Per-guest subvolumes and the pam_namespace instance parents. Must be on btrfs, the same filesystem as /nix.";
    };

    lowerDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/.guest-lower";
      description = "Where the read-only snapshots of /nix live (nested in the /nix subvolume, so later snapshots skip them).";
    };

    guestNixConf = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      internal = true;
      description = "Each guest's generated /etc/nix/nix.conf (for tests; the file is tmpfiles-copied).";
    };

    pamServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        [
          "login"
          "su"
          "systemd-user"
        ]
        ++ lib.optional config.services.openssh.enable "sshd"
        ++ lib.optional config.services.greetd.enable "greetd"
        ++ lib.optional config.security.sudo.enable "sudo";
      defaultText = lib.literalExpression ''[ "login" "su" "systemd-user" ] ++ sshd/greetd/sudo when enabled'';
      description = ''
        PAM services whose sessions put a guest into their namespace. Every way
        a guest's processes start must be here -- systemd-user is the user
        manager (user services, home-manager's units); a missing one runs that
        session on the system store, where the guest's own paths do not exist.
      '';
    };
  };

  config = lib.mkMerge [
    {
      my.guest-overlay.guestNixConf = lib.genAttrs names nixConfText;
      my.internal.features.guest-overlay = {
        requires = [ "btrfs-layout" ];
        enabledBy = cfg.enable;
      };
      assertions = [
        {
          assertion = (facts."guest-overlay" or false) == cfg.enable;
          message = ''
            registry/hosts.nix features.${hostName}."guest-overlay" = ${lib.boolToString (facts."guest-overlay" or false)}
            but my.guest-overlay.enable = ${lib.boolToString cfg.enable}. Fix whichever is wrong.'';
        }
      ];
    }

    (lib.mkIf active {
      assertions = lib.mapAttrsToList (n: u: {
        assertion = config.users.users.${n}.uid != null;
        message = "my.guest-overlay: ${n} needs a pinned uid (registry files always have one).";
      }) guests;

      environment.etc."security/namespace.conf".text = namespaceConf;

      security.pam.services = lib.genAttrs cfg.pamServices (svc: {
        rules.session.namespace = {
          # Right after pam_unix: before pam_systemd, so a login session and
          # the user manager it starts both see the guest's store.
          order = config.security.pam.services.${svc}.rules.session.unix.order + 60;
          control = "required";
          modulePath = "${config.security.pam.package}/lib/security/pam_namespace.so";
        };
      });

      systemd.tmpfiles.rules =
        [
          "d ${base} 0755 root root -"
          "d ${base}/.merged 0000 root root -"
          "d ${base}/.etc 0000 root root -"
          "d ${base}/.wrappers 0000 root root -"
        ]
        ++ lib.concatMap (n: [
          "d ${base}/.etc/${n} 0755 root root -"
          "C+ ${base}/.etc/${n}/nix.conf - - - - ${nixConf n}"
        ]) names;

      systemd.services =
        {
          nix-guest-lower = {
            description = "Frozen /nix snapshot for guest overlay stores";
            wantedBy = [ "multi-user.target" ];
            after = [ "local-fs.target" ];
            before = map (n: "nix-guest-overlay-${n}.service") names;
            restartIfChanged = false;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${snapshot} ${lroot} ${base} ${lib.escapeShellArgs names}";
            };
          };
        }
        // lib.listToAttrs (
          map (n: {
            name = "nix-guest-overlay-${n}";
            value = {
              description = "Overlay Nix store of ${n}";
              wantedBy = [ "multi-user.target" ];
              # Mounted before anyone can log in: pam_namespace would otherwise
              # bind the bare mountpoint (mode 0000) and the session would fail.
              before = [ "systemd-user-sessions.service" ];
              after = [
                "nix-guest-lower.service"
                "systemd-tmpfiles-setup.service"
              ];
              requires = [ "nix-guest-lower.service" ];
              # A switch must not unmount a guest's store under them; the
              # snapshot service asks for a rebase, which waits for a logout.
              restartIfChanged = false;
              stopIfChanged = false;
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = "${mountOverlay} ${lib.escapeShellArgs [
                  n
                  (uidOf n)
                  (groupOf n)
                  base
                  lroot
                  (if cfg.quota == null then "" else cfg.quota)
                ]}";
              };
            };
          }) names
        )
        // lib.listToAttrs (
          map (n: {
            name = "user@${uidOf n}";
            value = {
              overrideStrategy = "asDropin";
              wants = [ "nix-guest-overlay-${n}.service" ];
              after = [ "nix-guest-overlay-${n}.service" ];
              # Last session gone: the moment a pending rebase can happen.
              serviceConfig.ExecStopPost = "+${config.systemd.package}/bin/systemctl --no-block restart nix-guest-overlay-${n}.service";
            };
          }) names
        );

      # Every activation: new generation, new paths -- new guest sessions should
      # see them. Skipped in stage 2 (no systemd yet); the unit's wantedBy covers boot.
      system.activationScripts.nix-guest-lower = ''
        if [ -d /run/systemd/system ]; then
          ${config.systemd.package}/bin/systemctl start --no-block nix-guest-lower.service || true
        fi
      '';
    })
  ];
}
