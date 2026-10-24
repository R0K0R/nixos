/*
  features/nix/class-daemons and hm-switch's builder variations, evaluated.

  1. The class mapping on the three REAL hosts. my.class-daemons.layout is
     computed whether or not the feature is on, so this reads what each host
     WOULD get from the registry as it is: which classes, which members,
     which socket variants.
  2. A synthetic copy of galaxybook4-pro360 with the feature on (and the
     registry fact), plus two synthetic accounts: `mira` (type member, so a
     second class) and `guest` (handover, nix = none: no class daemon, never
     routed). Classes: admin (r0k0r) and member (mira, localJobs = 2 here only
     to evaluate a local variant -- the real gb4 builds nothing locally).
     Checked: the generated nix.conf / machines / ssh_config contents, the
     socket and service units, the group, the routing snippets, the shared
     daemon's nix.conf untouched, restrictDefault, and hm-switch's generated
     table.

  Evaluation only; nothing here starts a daemon. Every attribute is a string.
  `refused.*` must fail (assertions), reporting "refused". Run:
  tests/class-daemons-eval.sh.
*/
{ lib, mkHostWith }:

let
  host = "galaxybook4-pro360";

  extendWith =
    fact: raw:
    raw
    // {
      users = raw.users // {
        mira = {
          uid = 1903;
          type = "member";
          description = "Synthetic member";
        };
        guest = {
          uid = 1904;
          type = "handover";
          description = "Synthetic handover guest";
        };
      };
      hosts = raw.hosts // {
        hosts = raw.hosts.hosts // {
          ${host} = raw.hosts.hosts.${host} // {
            users = raw.hosts.hosts.${host}.users ++ [ "mira" "guest" ];
          };
        };
        features = raw.hosts.features // {
          ${host} = raw.hosts.features.${host} // {
            "class-daemons" = fact;
          };
        };
      };
    };

  hostWith =
    {
      fact ? true,
      enable ? true,
      extra ? { },
    }:
    mkHostWith {
      hostName = host;
      extraModules = [
        {
          my.registry.extend = extendWith fact;
          my.class-daemons.enable = enable;
          my.class-daemons.classes.member.localJobs = 2;
          my.epoch.hmSwitch.enable = true;
        }
        extra
      ];
    };

  on = hostWith { };
  c = on.config;
  L = c.my.class-daemons.layout;
  # Same accounts, feature off: the shared daemon's nix.conf must be the same.
  offSame = hostWith { enable = false; fact = false; };
  restricted = hostWith { extra.my.class-daemons.restrictDefault = true; };

  expect =
    what: cond: seen:
    if cond then seen else throw "class-daemons: ${what}: got ${seen}";
  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);
  mustFailWith =
    what: needle: cfg:
    if lib.any (lib.hasInfix needle) (failing cfg) then "refused" else throw "class-daemons: ${what} was accepted, should have been refused";

  summary =
    layout:
    lib.concatStringsSep "; " (
      lib.mapAttrsToList (
        cn: k: "${cn}[${lib.concatStringsSep " " k.members}]: ${lib.concatStringsSep " " (lib.attrNames k.variants)}"
      ) layout.classes
    );
  realLayout = h: (mkHostWith { hostName = h; }).config.my.class-daemons.layout;
  lines = s: lib.filter (l: l != "") (lib.splitString "\n" s);
  has = s: l: lib.elem l (lines s);

  m = L.classes.member;
  mDefault = m.variants.default.nixConf;
  mVictus = m.variants.victus-15.nixConf;
  mLocal = m.variants.local.nixConf;
  sock = c.systemd.sockets."nix-daemon-member-victus-15";
  svc = c.systemd.services."nix-daemon-member-victus-15";
  hmText = c.my.epoch.internal.tools.hm-switch.text;
in
{
  # -- 1. the real hosts ----------------------------------------------------
  real = {
    galaxybook4-pro360 = expect "gb4: admin r0k0r, pinnable victus-15 and yulee" (
      summary (realLayout "galaxybook4-pro360") == "admin[benjamin r0k0r]: default victus-15 yulee"
    ) (summary (realLayout "galaxybook4-pro360"));
    victus-15 = expect "victus-15: admin r0k0r benjamin, no peers -> default only" (
      summary (realLayout "victus-15") == "admin[benjamin r0k0r]: default"
    ) (summary (realLayout "victus-15"));
    dell-latitude = expect "dell-latitude: admin benjamin, both peers" (
      summary (realLayout "dell-latitude") == "admin[benjamin]: default victus-15 yulee"
    ) (summary (realLayout "dell-latitude"));
    gb4Off = expect "real gb4 has no class units" (
      !((mkHostWith { hostName = host; }).config.systemd.sockets ? "nix-daemon-admin-default")
    ) "none";
  };

  # -- 2. synthetic gb4, feature on -----------------------------------------
  classes = expect "admin + member, guest (nix = none) has none" (
    summary L == "admin[benjamin r0k0r]: default victus-15 yulee; member[mira]: default local victus-15 yulee"
  ) (summary L);
  routes = expect "routes: r0k0r, benjamin -> admin, mira -> member, no guest" (
    lib.mapAttrs (_: r: r.socket) L.routes == {
      r0k0r = "/nix/var/nix/daemon-socket-admin/default";
      benjamin = "/nix/var/nix/daemon-socket-admin/default";
      mira = "/nix/var/nix/daemon-socket-member/default";
    }
  ) (builtins.toJSON (lib.mapAttrs (_: r: r.socket) L.routes));

  confDefault = expect "member/default nix.conf" (
    has mDefault "include /etc/nix/nix.conf"
    && has mDefault "allowed-users = root @nix-class-member"
    && has mDefault "trusted-users = root"
    && has mDefault "builders = @/etc/nix/class-daemons/member-default/machines"
    && has mDefault "max-jobs = 0"
    && has mDefault "require-sigs = true"
    && has mDefault "sandbox = true"
    && lib.hasInfix "ssh-ng://nix-ssh@victus-15?priority=10" mDefault
    && lib.hasInfix "ssh-ng://r0k0r@yulee?priority=11" mDefault
    # include first: everything after it overrides the shared file
    && lib.head (lib.filter (l: !(lib.hasPrefix "#" l)) (lines mDefault)) == "include /etc/nix/nix.conf"
  ) mDefault;
  confPinned = expect "member/victus-15: that peer only" (
    has mVictus "max-jobs = 0"
    && has mVictus "builders = @/etc/nix/class-daemons/member-victus-15/machines"
    && lib.hasInfix "victus-15?priority=10" mVictus
    && !(lib.hasInfix "yulee" mVictus)
  ) mVictus;
  confLocal = expect "member/local: no builders, max-jobs 2, no peer stores" (
    has mLocal "builders =" && has mLocal "max-jobs = 2" && !(lib.hasInfix "ssh-ng://" mLocal)
  ) mLocal;
  machines = expect "machines: one line, the CLASS key" (
    m.variants.victus-15.machines
    == "ssh-ng://nix-ssh@victus-15 x86_64-linux,i686-linux /etc/nix/class-daemons/keys/member 5 4 benchmark,big-parallel,kvm,nixos-test,ca-derivations - -\n"
    && m.variants.local.machines == ""
    && lib.length (lines m.variants.default.machines) == 2
  ) m.variants.victus-15.machines;
  sshConfig = expect "ssh_config: class key only, own control path, no agent" (
    lib.hasInfix "IdentityFile /etc/nix/class-daemons/keys/member" m.sshConfig
    && lib.hasInfix "IdentitiesOnly yes" m.sshConfig
    && lib.hasInfix "IdentityAgent none" m.sshConfig
    && lib.hasInfix "ControlPath /run/nix-class-member-ssh-" m.sshConfig
    && !(lib.hasInfix "remote-builder-ssh-key" m.sshConfig)
  ) m.sshConfig;
  etcFiles = expect "etc: nix.conf + machines per variant, ssh_config per class" (
    lib.all (f: c.environment.etc ? ${f}) [
      "nix/class-daemons/member-default/nix.conf"
      "nix/class-daemons/member-local/machines"
      "nix/class-daemons/admin-yulee/nix.conf"
      "nix/class-daemons/member/ssh_config"
      "systemd/user-environment-generators/60-nix-class-daemon"
    ]
  ) "present";
  socketUnit = expect "socket: root:nix-class-member 0660 at the variant path" (
    sock.listenStreams == [ "/nix/var/nix/daemon-socket-member/victus-15" ]
    && sock.socketConfig.SocketGroup == "nix-class-member"
    && sock.socketConfig.SocketMode == "0660"
    && sock.wantedBy == [ "sockets.target" ]
  ) (builtins.toJSON sock.socketConfig);
  serviceUnit = expect "service: own NIX_CONF_DIR, ssh -F, the system's nix-daemon" (
    svc.environment.NIX_CONF_DIR == "/etc/nix/class-daemons/member-victus-15"
    && svc.environment.NIX_SSHOPTS == "-F /etc/nix/class-daemons/member/ssh_config"
    && svc.serviceConfig.ExecStart == "${c.nix.package.out}/bin/nix-daemon --daemon"
    && svc.environment ? CURL_CA_BUNDLE
  ) (builtins.toJSON { inherit (svc.environment) NIX_CONF_DIR NIX_SSHOPTS; inherit (svc.serviceConfig) ExecStart; });
  unitCount = expect "7 daemons: admin 3 + member 4" (
    lib.length (lib.filter (lib.hasPrefix "nix-daemon-") (lib.attrNames c.systemd.sockets)) == 7
  ) (toString (lib.filter (lib.hasPrefix "nix-daemon-") (lib.attrNames c.systemd.sockets)));
  group = expect "nix-class-member = mira; nix-class-admin = r0k0r" (
    c.users.groups.nix-class-member.members == [ "mira" ] && c.users.groups.nix-class-admin.members == [ "benjamin" "r0k0r" ]
  ) (builtins.toJSON c.users.groups.nix-class-member.members);
  routingShell = expect "extraInit routes mira and r0k0r, only if writable" (
    lib.hasInfix "mira) __ncd_s=/nix/var/nix/daemon-socket-member/default ;;" c.environment.extraInit
    && lib.hasInfix ''[ -w "$__ncd_s" ]'' c.environment.extraInit
    && !(lib.hasInfix "guest" c.environment.extraInit)
  ) "case arms for r0k0r, mira";
  sharedConfUnchanged = expect "the shared nix.conf is the same with the feature on" (
    c.environment.etc."nix/nix.conf".source.drvPath == offSame.config.environment.etc."nix/nix.conf".source.drvPath
  ) c.environment.etc."nix/nix.conf".source.drvPath;
  restrictDefault = expect "restrictDefault: the shared daemon admits root only (nobody here is nix = admin)" (
    restricted.config.nix.settings.allowed-users == [ "root" ]
  ) (toString restricted.config.nix.settings.allowed-users);
  hmSwitchTable = expect "hm-switch knows both routes and sudo for r0k0r only" (
    lib.hasInfix "mira) printf '%s\\n' /nix/var/nix/daemon-socket-member ;;" hmText
    && lib.hasInfix "r0k0r) printf '%s\\n' /nix/var/nix/daemon-socket-admin ;;" hmText
    && lib.hasInfix "    r0k0r) return 0 ;;" hmText
    && !(lib.hasInfix "mira) return 0" hmText)
  ) "routes + sudo table";
  noFailedAssertions = expect "no failed assertions" (failing on == [ ]) (builtins.toJSON (failing on));
  toplevel = on.config.system.build.toplevel.drvPath;

  # The generated pieces, whole, for reading (tests/class-daemons-eval.sh --files).
  files = {
    memberDefault = mDefault;
    memberVictus = mVictus;
    memberLocal = mLocal;
    memberMachines = m.variants.default.machines;
    memberSshConfig = m.sshConfig;
    extraInit = c.environment.extraInit;
    hmSwitch = hmText;
    userEnvGenerator = c.environment.etc."systemd/user-environment-generators/60-nix-class-daemon".source.text;
  };

  refused = {
    # A trusted class daemon is root-equivalent; mira is not nix = admin.
    trustedMember = mustFailWith "classes.member.trusted" "my.class-daemons.classes.member.trusted" (
      hostWith { extra.my.class-daemons.classes.member.trusted = true; }
    );
    # The registry fact must follow the switch.
    factMismatch = mustFailWith "enable without the fact" ''"class-daemons" = false'' (hostWith { fact = false; });
    unknownPeer = mustFailWith "builders naming a non-peer" "not in my.remote-builder.client.peers" (
      hostWith { extra.my.class-daemons.classes.member.builders = [ "note10" ]; }
    );
  };
}
