/*
  One extra nix-daemon per user CLASS, on the same store as the shared one
  (docs/multiuser-design.md, "Builders"). A class is a registry type
  (registry/types.nix: admin, member, ...); a class gets daemons on a host only
  if some account of that type lives there with daemon access (nix =
  "untrusted" or "admin"; "none" and "overlay" users never talk to a shared
  store daemon).

  WHY. Every setting that decides WHERE a build runs -- builders, max-jobs,
  substituters -- is a daemon setting, and people are untrusted on the shared
  daemon (registry: nix = "untrusted"), so it ignores them when they ask. Until
  now the only way to pin a builder was to become root (the nixos-rebuild-<peer>
  wrappers' sudo). A daemon of the class's own has the class's builders, the
  class's builder key and the class's max-jobs in ITS nix.conf, so the policy
  is per class and the users need no sudo to get it.

  LAYOUT, per class <c> present on this host:

    group     nix-class-<c>: the class's members on this host. The sockets are
              root:nix-class-<c> 0660 and the daemons' allowed-users is
              `root @nix-class-<c>`: nobody outside the class can connect.
    sockets   /nix/var/nix/daemon-socket-<c>/<variant>, one daemon each:
                default  the class's builders, the host's max-jobs
                <peer>   that peer ONLY (max-jobs 0, its own substituter) --
                         one per entry of the class's `builders`, unless
                         pinnable = false
                local    no remote builders, max-jobs = localJobs (only when
                         localJobs > 0; on a host whose policy is max-jobs = 0,
                         galaxybook's, it is 0 and there is no local variant)
              Socket-activated: an idle variant is a listening socket and
              nothing else.
    nix.conf  /etc/nix/class-daemons/<c>-<variant>/nix.conf, the daemon's
              NIX_CONF_DIR. It begins with `include /etc/nix/nix.conf` and
              then overrides only what is the class's: allowed-users,
              trusted-users, builders, max-jobs, substituters -- plus
              require-sigs, sandbox and sandbox-fallback restated. So
              experimental-features (ca-derivations), trusted-public-keys,
              system-features, sandbox paths, the signing key and anything a
              later feature adds are the shared daemon's by construction,
              never a copy that can drift.
    ssh       NIX_SSHOPTS = "-F /etc/nix/class-daemons/<c>/ssh_config". The
              daemon runs as root, and root's ssh_config (peer-*.nix) hands the
              HOST builder key to every connection to a peer (`Match ...
              localuser root` IdentityFile) -- ssh tries every IdentityFile it
              is given, so without -F a class daemon would silently also offer
              the host key, and the per-class key would mean nothing. -F
              replaces the system and user ssh_config; the class file names the
              peers' HostName, the class key with IdentitiesOnly, no agent, and
              a ControlPath of its own (sharing root's /run control socket
              would ride on a connection the HOST key authenticated).
    key       one builder key per class (sshKey / sshKeySecret), root 0400.
              Whoever reads it is whatever the peers make of it -- on a NixOS
              peer, the trusted nix-ssh account, if the peer lists its public
              half in my.remote-builder.server.extraKeys. That list is the
              real "which builders may this class use": a class daemon can
              only reach a peer that accepts its key. Never committed; the
              admin provisions it (see the runtime plan in the README).
    routing   NIX_REMOTE=unix://<default socket> for the class's members, set
              (only if unset, and only if the socket is writable for them) in
              two places: the shells' common init (environment.extraInit,
              sourced by bash, zsh and -- via fenv -- fish) and a systemd
              USER environment generator, so user services and anything a
              graphical session starts get it too. See ROUTING below.

  SECURITY MODEL. A second daemon on the same store is the same store: same
  /nix/store, same SQLite db, same build-trace (realisation) table. Whatever
  one daemon lets a client write, every other client -- root's system builds
  included -- reads. So what a class daemon may grant is bounded by what the
  registry already grants on the shared one:

    untrusted members (the default, and today everyone): exactly the shared
      daemon's rights. Nix enforces, for a client not in trusted-users: no
      path without a valid signature unless it is content-addressed (.drv
      files, CA outputs whose hash is the content), no registering build-trace
      rows, no changing sandbox, require-sigs, build hooks, extra-sandbox-paths
      or any other restricted setting, substituters only from the daemon's own
      list, and `builders` only set to "" (local-only). The class daemon adds
      nothing to that list; it only changes the DEFAULTS those builds run
      with. Picking a builder is therefore picking a socket, not passing a
      setting -- which is why every peer gets its own variant: it is the one
      way to give untrusted users a choice of builder that Nix itself does
      not have to trust them for.

    trusted = true (per class, off by default): members are added to that
      daemon's trusted-users. There is NO way in Nix to trust a client for
      `builders` and not for the rest: a trusted client may import unsigned
      paths (nix copy --no-check-sigs: a forged glibc under the right name),
      register realisations, turn off sandbox and require-sigs for its
      builds, set diff-hook / post-build-hook / build-hook (programs the
      daemon runs as ROOT), add extra-sandbox-paths. It is root on this
      machine and on every machine that later trusts this store. Restating
      sandbox / require-sigs in the file does not restrict it -- the client
      overrides them per connection. So `trusted` is accepted only for a class
      whose every member here already has nix = "admin" (trusted on the shared
      daemon anyway): a class daemon never widens trust, it only moves it.

    what remains, either way: sharing a store is sharing trust (the design
    doc's rule). An untrusted member's CA outputs built on a peer come back
    under that peer's signature and the host's trust in it; a member who can
    read the class key (nobody but root, by the mode) could talk to the peers
    as the class. Peers that accept a class key decide what that key may do
    there -- today nix-ssh, a trusted account, the same weight the host key
    has.

  ROUTING, and why there. NIX_REMOTE is what every Nix client consults, and it
  is convenience, not a boundary: a member who unsets it lands on the shared
  daemon, which still accepts him with the same (untrusted) rights unless
  restrictDefault is on. The places considered:
    - pam_env (environment.sessionVariables): every session, but one value for
      everyone -- pam_env.conf has no per-user or per-group condition.
    - ~/.config/nix/nix.conf `store = ...`: read by every client, but the
      user's own file -- the system cannot own it, an impermanent home loses
      it, and the first switch would have to write it from the wrong daemon.
    - a `nix` wrapper earlier on PATH: misses every absolute
      /nix/store/...-nix/bin/nix and every program that links libnixstore.
    - extraInit + a user environment generator (chosen): both are the system's,
      both evaluate per user at session start, together they cover login
      shells, ssh commands and the systemd user manager (home-manager's own
      units). Both check the socket is WRITABLE before routing: right after
      the switch that creates the group, a running session does not have it
      yet, and routing it would turn every nix call into EACCES until the next
      login.

  OFF by default; the registry fact features.<host>."class-daemons" must agree.
  Never run on hardware yet: tests/class-daemons-eval.sh evaluates the layout.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.class-daemons;
  hostName = config.networking.hostName;
  reg = config.my.registry.loaded;
  facts = reg.hosts.features.${hostName} or { };
  rb = config.my.remote-builder.client;

  # Registry users of this host with daemon access, and their class (type).
  effective = reg.effective.${hostName} or { };
  daemonUsers = lib.filterAttrs (_: e: lib.elem e.nix [ "untrusted" "admin" ]) effective;
  classOf = n: reg.users.${n}.type;
  present = lib.unique (map classOf (lib.attrNames daemonUsers));
  membersOf = c: lib.filter (n: classOf n == c) (lib.attrNames daemonUsers);

  groupOf = c: "nix-class-${c}";
  socketDir = c: "${cfg.socketBase}-${c}";
  confDir = c: v: "nix/class-daemons/${c}-${v}";
  sshConfigPath = c: "/etc/nix/class-daemons/${c}/ssh_config";
  keyPath = c: cfg.classes.${c}.sshKey;

  hostMaxJobs = toString config.nix.settings.max-jobs;

  # "ssh-ng://user@host?priority=10" -> "host"
  sshHost =
    s:
    let
      rest = lib.removePrefix "ssh-ng://" s;
      noUser = lib.last (lib.splitString "@" rest);
    in
    lib.head (lib.splitString "?" noUser);
  isSsh = s: lib.hasPrefix "ssh-ng://" s || lib.hasPrefix "ssh://" s;
  # The shared daemon's substituters, keeping peer stores only for the given
  # peers -- and spelled exactly as the shared list spells them (priorities).
  substitutersFor = peers: lib.filter (s: !(isSsh s) || lib.elem (sshHost s) peers) config.nix.settings.substituters;

  # Same fields /etc/nix/machines carries (nix.buildMachines in
  # remote-builder), with the CLASS key. Parked peers keep a line in their own
  # pinned variant, like the nixos-rebuild-<peer> wrappers: pinning a parked
  # peer is how one checks whether it is back.
  machineLine =
    c: name:
    let
      p = rb.peers.${name};
      feats = if p.features == [ ] then "-" else lib.concatStringsSep "," p.features;
    in
    "ssh-ng://${p.daemonUser}@${name} x86_64-linux,i686-linux ${keyPath c} ${toString p.maxJobs} ${toString p.speedFactor} ${feats} - -";

  variantsOf =
    c:
    let
      k = cfg.classes.${c};
    in
    {
      default = {
        peers = lib.filter (n: rb.peers.${n}.enable) k.builders;
        maxJobs = hostMaxJobs;
        substituters = substitutersFor k.builders;
      };
    }
    // lib.optionalAttrs k.pinnable (
      lib.genAttrs k.builders (n: {
        peers = [ n ];
        maxJobs = "0";
        substituters = substitutersFor [ n ];
      })
    )
    // lib.optionalAttrs (k.localJobs > 0) {
      local = {
        peers = [ ];
        maxJobs = toString k.localJobs;
        substituters = substitutersFor [ ];
      };
    };

  machinesText = c: v: lib.concatMapStrings (n: machineLine c n + "\n") v.peers;

  nixConfText =
    c: vn: v:
    let
      k = cfg.classes.${c};
    in
    ''
      # nix-daemon of user class "${c}", variant "${vn}" (features/nix/class-daemons).
      # Everything not set below is the shared daemon's own configuration.
      include /etc/nix/nix.conf
      allowed-users = root @${groupOf c}
      trusted-users = root${lib.concatMapStrings (n: " " + n) (lib.optionals k.trusted (membersOf c))}
      builders =${lib.optionalString (v.peers != [ ]) " @/etc/${confDir c vn}/machines"}
      max-jobs = ${v.maxJobs}
      substituters = ${lib.concatStringsSep " " v.substituters}
      # Restated, so this daemon's defaults are safe whatever the shared file
      # says. A TRUSTED client can still override them per connection; see the
      # feature header.
      require-sigs = true
      sandbox = true
      sandbox-fallback = false
    ''
    + k.extraConfig;

  sshConfigText =
    c:
    lib.concatMapStrings (n: ''
      Host ${n}
        HostName ${rb.peers.${n}.address}
        IdentityFile ${keyPath c}
        ControlMaster auto
        ControlPath /run/nix-class-${c}-ssh-%r@%h:%p
        ControlPersist yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '') cfg.classes.${c}.builders
    + ''
      Host *
        IdentitiesOnly yes
        IdentityAgent none
        StrictHostKeyChecking yes
        GlobalKnownHostsFile /etc/ssh/ssh_known_hosts
    '';

  layout = {
    classes = lib.genAttrs present (c: {
      members = membersOf c;
      group = groupOf c;
      inherit (cfg.classes.${c}) trusted;
      sshKey = keyPath c;
      sshConfig = sshConfigText c;
      socketDir = socketDir c;
      variants = lib.mapAttrs (vn: v: {
        socket = "${socketDir c}/${vn}";
        unit = "nix-daemon-${c}-${vn}";
        nixConf = nixConfText c vn v;
        machines = machinesText c v;
        inherit (v) peers maxJobs;
      }) (variantsOf c);
    });
    # user -> { class; dir; socket (the default variant) }
    routes = lib.listToAttrs (
      map (n: {
        name = n;
        value = {
          class = classOf n;
          dir = socketDir (classOf n);
          socket = "${socketDir (classOf n)}/default";
        };
      }) (lib.attrNames daemonUsers)
    );
  };

  instances = lib.concatLists (
    lib.mapAttrsToList (c: k: lib.mapAttrsToList (vn: v: v // { inherit c vn; }) k.variants) layout.classes
  );

  # `case` arms for the routing snippets: user) socket ;;
  routeCases = lib.concatStrings (
    lib.mapAttrsToList (n: r: "    ${lib.escapeShellArg n}) __ncd_s=${lib.escapeShellArg r.socket} ;;\n") layout.routes
  );
  # Shell-init variables are namespaced: this runs inside every user shell.
  routeBody = ''
    case "$__ncd_u" in
    ${routeCases}    *) __ncd_s= ;;
    esac
  '';

  userEnvGenerator = pkgs.writeShellScript "nix-class-daemon-env" ''
    # systemd user environment generator: route this user's Nix clients to the
    # daemon of their class (features/nix/class-daemons). Prints nothing when
    # NIX_REMOTE is already set or the socket is not usable yet.
    [ -n "''${NIX_REMOTE:-}" ] && exit 0
    __ncd_u=$(${pkgs.coreutils}/bin/id -un)
    ${routeBody}
    if [ -n "$__ncd_s" ] && [ -S "$__ncd_s" ] && [ -w "$__ncd_s" ]; then
      printf 'NIX_REMOTE=unix://%s\n' "$__ncd_s"
    fi
  '';

  classModule =
    { name, config, ... }:
    {
      options = {
        builders = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = if rb.enable then lib.attrNames (lib.filterAttrs (_: p: p.enable) rb.peers) else [ ];
          defaultText = lib.literalExpression "the enabled peers of my.remote-builder.client, or [ ]";
          description = ''
            Peers (names in my.remote-builder.client.peers) this class's
            daemons dispatch to. Each also gets a pinned socket (see
            `pinnable`). The class key must be accepted by each of them --
            that, not this list, is what finally decides.
          '';
        };
        pinnable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "One socket per builder that builds on that peer only.";
        };
        localJobs = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 0;
          description = ''
            max-jobs of the `local` variant (no remote builders). 0: no local
            variant -- the default, because a host's no-local-builds policy
            (max-jobs = 0, registry fact localBuilds = false) is for everyone.
          '';
        };
        trusted = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Put the class's members into its daemons' trusted-users. Root-
            equivalent (feature header); accepted only when every member on
            this host already has nix = "admin".
          '';
        };
        sshKeySecret = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          example = lib.literalExpression "../../age/nix-class-member-ssh-key.age";
          description = ''
            agenix file with this class's builder key (decrypted to
            /run/agenix/nix-class-${name}-ssh-key, root 0400). Null: a hand-
            provisioned file at `sshKey`. Requires my.agenix.enable.
          '';
        };
        sshKey = lib.mkOption {
          type = lib.types.str;
          default =
            if config.sshKeySecret != null then
              "/run/agenix/nix-class-${name}-ssh-key"
            else
              "/etc/nix/class-daemons/keys/${name}";
          defaultText = lib.literalExpression ''
            "/run/agenix/nix-class-<class>-ssh-key" with sshKeySecret, else "/etc/nix/class-daemons/keys/<class>"
          '';
          description = ''
            Path of the class's builder private key, read by the class daemons
            (root) at connect time. Defaults to the agenix path when
            sshKeySecret is set, a hand-provisioned root 0400 file otherwise.
          '';
        };
        extraConfig = lib.mkOption {
          type = lib.types.lines;
          default = "";
          description = "Appended to every variant's nix.conf of this class.";
        };
      };
    };
in
{
  options.my.class-daemons = {
    enable = lib.mkEnableOption ''
      one nix-daemon per user class (registry type) present on this host,
      with its own nix.conf, sockets, builders and builder key; members are
      routed to it with NIX_REMOTE. The registry fact
      features.<host>."class-daemons" must say so too'';

    classes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule classModule);
      default = { };
      description = ''
        Per-class policy, keyed by registry type. Every class present on the
        host exists here with defaults; set only what differs.
      '';
    };

    socketBase = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/daemon-socket";
      description = "Class <c>'s sockets live in <socketBase>-<c>/<variant>.";
    };

    restrictDefault = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Take the class daemons' untrusted members off the SHARED daemon's
        allowed-users (the design's "default daemon: root + admin"). Off by
        default: anything of theirs that runs without NIX_REMOTE -- a system
        unit with User=, a session that started before the switch -- then
        fails to connect instead of falling back to the shared daemon.
      '';
    };

    layout = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      default = layout;
      description = ''
        What the feature generates, as data (tests, hm-switch): classes.<c> =
        { members; group; trusted; sshKey; sshConfig; socketDir; variants.<v> =
        { socket; unit; nixConf; machines; peers; maxJobs; }; } and
        routes.<user> = { class; dir; socket; }. Computed whether or not the
        feature is on.
      '';
    };
  };

  config = lib.mkMerge [
    {
      # Every present class exists with its defaults.
      my.class-daemons.classes = lib.genAttrs present (_: { });

      my.internal.features."class-daemons".enabledBy = cfg.enable;
      my.internal.features."class-daemons.builders" = {
        requires = [ "remote-builder.client" ];
        enabledBy = cfg.enable && lib.any (c: cfg.classes.${c}.builders != [ ]) present;
      };
      my.internal.features."class-daemons.agenix" = {
        requires = [ "agenix" ];
        enabledBy = cfg.enable && lib.any (c: cfg.classes.${c}.sshKeySecret != null) present;
      };

      assertions = [
        {
          assertion = (facts."class-daemons" or false) == cfg.enable;
          message = ''
            registry/hosts.nix features.${hostName}."class-daemons" = ${lib.boolToString (facts."class-daemons" or false)}
            but my.class-daemons.enable = ${lib.boolToString cfg.enable}. Fix whichever is wrong.'';
        }
      ];
    }

    (lib.mkIf cfg.enable {
      warnings = map (c: "my.class-daemons.classes.${c}: no account of type \"${c}\" with daemon access lives on ${hostName}; ignored.") (
        lib.subtractLists present (lib.attrNames cfg.classes)
      );

      assertions = lib.concatMap (
        c:
        let
          k = cfg.classes.${c};
          notAdmin = lib.filter (n: effective.${n}.nix != "admin") (membersOf c);
          unknown = lib.filter (n: !(rb.peers ? ${n})) k.builders;
          clash = lib.intersectLists [ "default" "local" ] k.builders;
        in
        [
          {
            assertion = !k.trusted || notAdmin == [ ];
            message = ''
              my.class-daemons.classes.${c}.trusted: ${lib.concatStringsSep ", " notAdmin} not nix = "admin" on
              ${hostName}. A trusted client of ANY daemon on this store can import unsigned paths and
              run hooks as root; a class daemon may not grant what the registry does not.'';
          }
          {
            assertion = unknown == [ ];
            message = "my.class-daemons.classes.${c}.builders: ${lib.concatStringsSep ", " unknown} not in my.remote-builder.client.peers";
          }
          {
            assertion = clash == [ ];
            message = "my.class-daemons.classes.${c}.builders: a peer may not be called ${lib.concatStringsSep "/" clash} (a socket variant name)";
          }
        ]
      ) present;

      my.registry.nix.defaultDaemonExcludes = lib.mkIf cfg.restrictDefault (
        lib.filter (n: effective.${n}.nix != "admin") (lib.attrNames daemonUsers)
      );

      users.groups = lib.listToAttrs (
        map (c: {
          name = groupOf c;
          value.members = membersOf c;
        }) present
      );

      environment.etc = lib.listToAttrs (
        lib.concatMap (i: [
          {
            name = "${confDir i.c i.vn}/nix.conf";
            value.text = i.nixConf;
          }
          {
            name = "${confDir i.c i.vn}/machines";
            value.text = i.machines;
          }
        ]) instances
        ++ map (c: {
          name = lib.removePrefix "/etc/" (sshConfigPath c);
          value.text = layout.classes.${c}.sshConfig;
        }) present
      )
      // {
        "systemd/user-environment-generators/60-nix-class-daemon".source = userEnvGenerator;
      };

      environment.extraInit = ''
        # Route this user's Nix clients to the daemon of their class
        # (features/nix/class-daemons), unless NIX_REMOTE is already set.
        if [ -z "''${NIX_REMOTE:-}" ]; then
          __ncd_u=''${USER:-$(id -un 2>/dev/null)}
          ${routeBody}
          if [ -n "$__ncd_s" ] && [ -S "$__ncd_s" ] && [ -w "$__ncd_s" ]; then
            export NIX_REMOTE="unix://$__ncd_s"
          fi
          unset __ncd_u __ncd_s
        fi
      '';

      age.secrets = lib.listToAttrs (
        map (c: {
          name = "nix-class-${c}-ssh-key";
          value = {
            file = cfg.classes.${c}.sshKeySecret;
            owner = "root";
            group = "root";
            mode = "0400";
          };
        }) (lib.filter (c: cfg.classes.${c}.sshKeySecret != null) present)
      );

      # Hand-provisioned keys: root-only, and kept across an impermanent root.
      systemd.tmpfiles.rules = map (c: "z ${keyPath c} 0400 root root -") (
        lib.filter (c: cfg.classes.${c}.sshKeySecret == null) present
      );
      my.state.system.secret.files = map keyPath (lib.filter (c: !(lib.hasPrefix "/run/" (keyPath c))) present);

      systemd.sockets = lib.listToAttrs (
        map (i: {
          name = i.unit;
          value = {
            description = "Nix daemon socket, class ${i.c} (${i.vn})";
            wantedBy = [ "sockets.target" ];
            listenStreams = [ i.socket ];
            unitConfig.RequiresMountsFor = [ "/nix/store" ];
            socketConfig = {
              SocketUser = "root";
              SocketGroup = groupOf i.c;
              SocketMode = "0660";
              DirectoryMode = "0755";
            };
          };
        }) instances
      );

      systemd.services = lib.listToAttrs (
        map (
          i:
          let
            shared = config.systemd.services.nix-daemon;
          in
          {
            name = i.unit;
            value = {
              description = "Nix daemon, class ${i.c} (${i.vn})";
              # The shared daemon's PATH (nix, ssh, ...) and environment
              # (CA bundle, proxy), plus this daemon's own files.
              inherit (shared) path;
              environment = removeAttrs shared.environment [ "PATH" ] // {
                NIX_CONF_DIR = "/etc/${confDir i.c i.vn}";
                NIX_SSHOPTS = "-F ${sshConfigPath i.c}";
              };
              unitConfig.RequiresMountsFor = [
                "/nix/store"
                "/nix/var"
                "/nix/var/nix/db"
              ];
              restartTriggers = [
                config.environment.etc."nix/nix.conf".source
                config.environment.etc."${confDir i.c i.vn}/nix.conf".source
              ];
              # As upstream's nix-daemon: keep the socket up across a switch.
              stopIfChanged = false;
              serviceConfig = {
                ExecStart = "${config.nix.package.out}/bin/nix-daemon --daemon";
                KillMode = "process";
                LimitNOFILE = 1048576;
                TasksMax = 1048576;
                inherit (shared.serviceConfig) CPUSchedulingPolicy IOSchedulingClass IOSchedulingPriority;
              };
            };
          }
        ) instances
      );
    })
  ];
}
