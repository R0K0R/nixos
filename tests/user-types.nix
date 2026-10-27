/*
  The handover and untrusted user types, and the deployed-type record, on a
  synthetic copy of galaxybook4-pro360. No real host has such a user (and
  none records types), so this is the only place that machinery is
  evaluated.

  The synthetic registry (my.registry.extend) adds two accounts to gb4:

    guest    handover: tmpfs home (1G), nix = none, kiosk firefox (pinned),
             handover.expires = "2026-12-31"
    visitor  untrusted, with nix overridden to "untrusted" and
             narrow.localBuilds = false (true anyway on gb4, max-jobs = 0),
             acceptTypeChange = "member->untrusted"

  The real host (`off`) has guest (untrusted) and handoff (handover, tmpfs
  home) pinned to GNOME (session = { desktop = "gnome"; }, my.gnome):
  `gnome*` checks the greeter-only pin, the greeter entry and the guard's
  pass-through, and -- against the same host with my.gnome forced off
  (`noGnome`) -- that GNOME reaches nothing of r0k0r's: the epoch, the
  environment, the system packages and his home's drvPath are identical.

  Every attribute is a string; forcing the set evaluates everything and
  builds nothing. Run with builds disabled (tests/user-types-eval.sh). Each
  check either returns a short description of what it saw or throws saying
  what was wrong. `refused.*` are the negative cases: each must FAIL to
  evaluate, and reports "refused: <message>" when it does.
*/
{ lib, mkHostWith, mkHomeLib }:

let
  host = "galaxybook4-pro360";

  extend =
    raw:
    raw
    // {
      users = raw.users // {
        guest = {
          uid = 1900;
          type = "handover";
          description = "Handover guest";
          tmpfsSize = "1G";
          handover.expires = "2026-12-31";
        };
        visitor = {
          uid = 1901;
          type = "untrusted";
          overrides.nix = "untrusted";
          acceptTypeChange = "member->untrusted";
        };
      };
      hosts = raw.hosts // {
        hosts = raw.hosts.hosts // {
          ${host} = raw.hosts.hosts.${host} // {
            # Its own list, not the host's plus these: the real host now has a
            # guest and a handoff of its own (registry/users), and the checks
            # below are about exactly these accounts.
            users = [ "r0k0r" "benjamin" "guest" "visitor" ];
            # Added to the host's own narrowing, not in place of it: `//`
            # on `narrow` would drop narrow.r0k0r.home = "impermanent".
            narrow = (raw.hosts.hosts.${host}.narrow or { }) // { visitor.localBuilds = false; };
          };
        };
      };
    };

  on = mkHostWith {
    hostName = host;
    extraModules = [
      {
        my.registry.extend = extend;
        my.registry.recordTypes.enable = true;
      }
    ];
  };
  off = mkHostWith { hostName = host; };

  # The same synthetic host with sshd on (gb4 runs none): the ssh refusal.
  withSsh = mkHostWith {
    hostName = host;
    extraModules = [
      {
        my.registry.extend = extend;
        services.openssh.enable = true;
      }
    ];
  };

  # visitor trusted by hand, past the registry: the nix-access assertion
  # must catch it. Only config.assertions is forced, not the toplevel.
  trustedByHand = mkHostWith {
    hostName = host;
    extraModules = [
      {
        my.registry.extend = extend;
        my.registry.nix.extraTrustedUsers = [ "visitor" ];
      }
    ];
  };

  # The real host with GNOME switched off (guest and handoff keep their
  # registry session, so the feature's assertion must fire; only
  # config.assertions and leaf values are forced, never the toplevel).
  noGnome = mkHostWith {
    hostName = host;
    extraModules = [ { my.gnome.enable = lib.mkForce false; } ];
  };

  /*
    visitor with a standalone home-manager session: the untuned account
    with a home that no real host has yet. Its home must default to an
    untuned set -- and on gb4, a march host, be refused by the surface check
    until the perl/sqlite decision. `untunedIntegrated` is the same account
    with an integrated home, which cannot be untuned at all.
  */
  withVisitorHome =
    activation:
    raw:
    let
      r = extend raw;
    in
    r // { users = r.users // { visitor = r.users.visitor // { overrides = r.users.visitor.overrides // { session = "home-manager"; }; homeActivation = activation; }; }; };
  untunedHome = mkHostWith {
    hostName = host;
    extraModules = [ { my.registry.extend = withVisitorHome "standalone"; } ];
  };
  untunedIntegrated = mkHostWith {
    hostName = host;
    extraModules = [ { my.registry.extend = withVisitorHome "system"; } ];
  };

  c = on.config;
  reg = c.my.registry.loaded;
  facts = (mkHomeLib host on).facts;

  expect =
    what: cond: seen:
    if cond then seen else throw "user-types: ${what}: got ${seen}";

  mount = lib.findFirst (m: m.where == "/home/guest") (throw "no mount for /home/guest") c.systemd.mounts;
  mountUnit = c.systemd.units."home-guest.mount".text;
  sessionNames = lib.concatMap (p: p.providedSessions or [ ]) c.services.displayManager.sessionPackages;
  kioskEntry = lib.findFirst (p: p.providedSessions or [ ] == [ "kiosk-firefox" ]) (throw "no kiosk-firefox session") c.services.displayManager.sessionPackages;
  preSwitch = c.system.preSwitchChecks.nixos-user-types;
  visitorBlock = lib.findFirst (lib.hasInfix "/var/lib/nixos-users/visitor.type") (throw "no visitor block in the pre-switch check") (
    lib.splitString "rec_file=" preSwitch
  );

  # A negative case: must throw. tryEval only sees throw/assert, which is
  # all the registry and the checks below use.
  mustFail =
    what: v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then throw "user-types: ${what} was accepted, should have been refused" else "refused";

  T = reg.transition;
  rec' = type: home: nix: { inherit type home nix; };

  # A registry with one change on top of the synthetic one, loaded directly
  # (no NixOS evaluation needed for registry-level refusals).
  regWith = f: import ../registry { inherit lib; extend = raw: f (extend raw); };
in
{
  toplevel = c.system.build.toplevel.drvPath;

  # -- tmpfs home --------------------------------------------------------
  tmpfsMount = expect "mount options" (
    lib.hasInfix "size=1G" mount.options && lib.hasInfix "uid=1900" mount.options && lib.hasInfix "gid=100" mount.options
  ) mount.options;
  tmpfsUnit = expect "mount unit tied to user@1900" (
    lib.hasInfix "PartOf=user@1900.service" mountUnit
    && lib.hasInfix "Before=user@1900.service" mountUnit
    && lib.hasInfix "LazyUnmount=true" mountUnit
  ) "PartOf/Before user@1900.service, LazyUnmount";
  tmpfsRequiredBy = expect "required by user@1900" (lib.elem "user@1900.service" mount.requiredBy) (toString mount.requiredBy);
  guestAccount = expect "guest account" (
    c.users.users.guest.createHome == false && c.users.users.guest.uid == 1900 && !(c.home-manager.users ? guest)
  ) "uid 1900, createHome false, no home-manager";
  logind = expect "logind kills only guest" (
    c.services.logind.settings.Login.KillUserProcesses && c.services.logind.settings.Login.KillOnlyUsers == "guest"
  ) "KillUserProcesses=yes KillOnlyUsers=${c.services.logind.settings.Login.KillOnlyUsers}";
  # The real gb4's one tmpfs home is handoff's: logind kills only that
  # account's processes at logout, never r0k0r's (KillOnlyUsers).
  realHostLogind = expect "real gb4 logind kills only handoff" (
    off.config.services.logind.settings.Login.KillUserProcesses
    && (off.config.services.logind.settings.Login.KillOnlyUsers or null) == "handoff"
  ) "KillOnlyUsers=${toString (off.config.services.logind.settings.Login.KillOnlyUsers or "unset")}";

  # -- kiosk session -----------------------------------------------------
  sessions = expect "kiosk-firefox offered" (lib.elem "kiosk-firefox" sessionNames) (toString sessionNames);
  kioskSession = kioskEntry.drvPath;
  kioskOnce = expect "one kiosk entry" (lib.length (lib.filter (lib.hasPrefix "kiosk-") sessionNames) == 1) (toString sessionNames);

  # -- kiosk pinning -----------------------------------------------------
  # One launcher, used three ways: login shell, greeter entry, /etc/profile pin.
  kioskShell = expect "guest's login shell is the kiosk launcher" (
    c.users.users.guest.shell == "/run/current-system/sw/bin/kiosk-shell-firefox"
  ) (toString c.users.users.guest.shell);
  kioskShellNotListed = expect "launcher not in /etc/shells (su -s stays refused)" (
    !(lib.hasInfix "kiosk-shell" c.environment.etc.shells.text)
  ) "absent";
  profilePin =
    let
      d = builtins.unsafeDiscardStringContext;
      head' = d (lib.head (lib.splitString "__ETC_PROFILE_SOURCED" c.environment.etc.profile.text));
    in
    expect "/etc/profile execs the launcher for uid 1900 before its sourced-once guard" (
      builtins.match ".*1900\\) exec /nix/store/[a-z0-9]+-kiosk-shell-firefox/bin/kiosk-shell-firefox ;;.*" head' != null
    ) head';
  visitorUnpinned = expect "visitor (no kiosk) keeps the default shell, is not pinned" (
    !(lib.hasInfix "1901)" c.environment.etc.profile.text) && !(lib.hasInfix "kiosk-shell" (toString (c.users.users.visitor.shell or "")))
  ) (toString (c.users.users.visitor.shell or "default"));
  sshDenied =
    let
      sc = withSsh.config;
      acct = lib.filter (lib.hasPrefix "account") (lib.splitString "\n" sc.security.pam.services.sshd.text);
    in
    expect "with sshd on: DenyUsers guest, and sshd's account stack refuses guest first" (
      !c.services.openssh.enable
      && sc.services.openssh.settings.DenyUsers == [ "guest" ]
      && lib.hasInfix "pam_succeed_if.so quiet user notin guest" (lib.head acct)
    ) "DenyUsers ${builtins.toJSON sc.services.openssh.settings.DenyUsers}; ${lib.head acct}";
  suRefused =
    let
      t = c.security.pam.services.su.text;
      acct = lib.filter (lib.hasPrefix "account") (lib.splitString "\n" t);
    in
    expect "su: pam_succeed_if notin guest first in the account stack" (
      acct != [ ] && lib.hasInfix "pam_succeed_if.so quiet user notin guest" (lib.head acct)
    ) (lib.concatStringsSep " | " acct);

  # -- handover credentials ----------------------------------------------
  credentialFile = expect "guest's hash file is under persistRoot (gb4 is impermanent), expiry from the registry" (
    c.users.users.guest.hashedPasswordFile == "/persist/var/lib/handover/guest.hash" && c.users.users.guest.expires == "2026-12-31"
  ) "${toString c.users.users.guest.hashedPasswordFile} expires ${toString c.users.users.guest.expires}";
  credentialSeed = expect "the locked seed is written before the users script" (
    lib.elem "handover-credentials" c.system.activationScripts.users.deps
    && lib.hasInfix "/persist/var/lib/handover" (let a = c.system.activationScripts.handover-credentials; in if lib.isString a then a else a.text)
  ) (toString c.system.activationScripts.users.deps);
  deadlinePam =
    let
      acct = svc: lib.filter (lib.hasPrefix "account") (lib.splitString "\n" c.security.pam.services.${svc}.text);
    in
    expect "login checks the deadline first in its account stack; greetd's account is `include login`" (
      lib.hasInfix "# handover-deadline" (lib.head (acct "login"))
      && lib.hasInfix "pam_exec.so quiet seteuid" (lib.head (acct "login"))
      && lib.length (acct "greetd") == 1
      && lib.hasPrefix "account include login" (lib.head (acct "greetd"))
    ) (lib.concatStringsSep " | " (acct "login" ++ acct "greetd"));
  handoverTool = expect "handover command installed" (
    lib.any (p: (p.name or "") == "handover") c.environment.systemPackages
  ) "present";
  visitorPassword = expect "visitor's password is not handover-managed" (
    (c.users.users.visitor.hashedPasswordFile or null) == null
  ) "untouched";

  # -- nix access --------------------------------------------------------
  allowedUsers = expect "allowed-users excludes guest" (
    c.nix.settings.allowed-users == [ "root" "benjamin" "r0k0r" "visitor" ]
  ) (toString c.nix.settings.allowed-users);
  # The real gb4 has guest and handoff (nix = none) since 2026-10-24, so its
  # daemon admits only the accounts with store access.
  realHostAllowedUsers = expect "real gb4: allowed-users = root + the people with store access (guest, handoff have nix = none)" (off.config.nix.settings.allowed-users == [ "root" "benjamin" "r0k0r" ]) (
    toString off.config.nix.settings.allowed-users
  );
  nixConf = expect "nix.conf differs from the real host's" (
    c.environment.etc."nix/nix.conf".source.drvPath != off.config.environment.etc."nix/nix.conf".source.drvPath
  ) c.environment.etc."nix/nix.conf".source.drvPath;
  trustedUsers = expect "trusted-users = root (no registry person is nix = admin)" (c.nix.settings.trusted-users == [ "root" ]) (
    toString c.nix.settings.trusted-users
  );
  trustedByHandCaught = expect "extraTrustedUsers naming visitor fails an assertion" (
    lib.any (a: !a.assertion && lib.hasInfix "my.users.visitor " a.message) trustedByHand.config.assertions
  ) (toString trustedByHand.config.nix.settings.trusted-users);

  # -- groups (from grants) ---------------------------------------------
  groups = expect "groups follow grants: r0k0r admin+serial, guest and visitor none" (
    lib.mapAttrs (_: u: u.extraGroups) (lib.getAttrs [ "guest" "visitor" ] c.users.users) == { guest = [ ]; visitor = [ ]; }
    && lib.all (g: lib.elem g c.users.users.r0k0r.extraGroups) [ "wheel" "networkmanager" "video" "audio" "dialout" ]
  ) (builtins.toJSON (lib.mapAttrs (_: u: u.extraGroups) (lib.getAttrs [ "r0k0r" "guest" "visitor" ] c.users.users)));

  # -- home cutover -----------------------------------------------------
  standaloneHome = expect "r0k0r standalone: not integrated, CLI shipped, home still evaluable" (
    !(c.home-manager.users ? r0k0r)
    && lib.any (p: (p.pname or p.name or "") == "home-manager") c.environment.systemPackages
    && !(
      (mkHomeLib host on).mkHome {
        username = "r0k0r";
        # His home is impermanent here, and an impermanent home with an
        # empty my.persist is refused (lib/home-persist.nix); his real list
        # lives in his home repo.
        modules = [ { my.persist.directories = [ "KSA" ]; } ];
      }
    ).config.submoduleSupport.enable
  ) (toString (lib.attrNames c.home-manager.users));

  /*
    -- home axis: persistent -> impermanent -> tmpfs ----------------------
    impermanent is accepted where the host's registry facts declare
    impermanence (gb4 does), and a host may NARROW a home to one that keeps
    less across a reboot -- r0k0r is persistent in his user file and
    narrowed to impermanent on gb4 only (registry/hosts.nix). Widening is
    refused (refused.narrowWiden*).
  */
  homeNarrowed = expect "r0k0r: persistent in the user file, impermanent on gb4 only, persistent on victus-15" (
    reg.effective.${host}.r0k0r.home == "impermanent"
    && c.my.users.r0k0r.impermanentHome
    && reg.effective.victus-15.r0k0r.home == "persistent"
  ) "${reg.effective.${host}.r0k0r.home} on gb4, ${reg.effective.victus-15.r0k0r.home} on victus-15";
  impermanentAccepted =
    let
      e = (regWith (r: r // { users = r.users // { visitor = r.users.visitor // { overrides.home = "impermanent"; }; }; })).effective.${host}.visitor;
    in
    expect "home = impermanent accepted on gb4 (declares impermanence)" (e.home == "impermanent") e.home;
  narrowToTmpfs =
    let
      e = (regWith (r: r // { hosts = r.hosts // { hosts = r.hosts.hosts // { ${host} = r.hosts.hosts.${host} // { narrow = r.hosts.hosts.${host}.narrow // { visitor = r.hosts.hosts.${host}.narrow.visitor // { home = "tmpfs"; }; }; }; }; }; })).effective.${host}.visitor;
    in
    expect "narrow persistent -> tmpfs accepted" (e.home == "tmpfs") e.home;

  # -- uids --------------------------------------------------------------
  uids = expect "every registry account has its registry uid" (
    lib.mapAttrs (_: u: u.uid) (lib.getAttrs [ "r0k0r" "guest" "visitor" ] c.users.users)
    == { r0k0r = 1000; guest = 1900; visitor = 1901; }
  ) (builtins.toJSON (lib.mapAttrs (_: u: u.uid) (lib.getAttrs [ "r0k0r" "guest" "visitor" ] c.users.users)));

  # -- homeLib facts -----------------------------------------------------
  factsVisitor =
    let
      v = facts.nix.users.visitor;
    in
    expect "visitor facts" (
      v.daemon && !v.trusted && !v.builds.local && v.builds.remote && !v.ownBuilders && facts.users.visitor.nix == "untrusted"
    ) (builtins.toJSON v);
  factsGuest =
    let
      g = facts.nix.users.guest;
    in
    expect "guest facts" (!g.daemon && !g.builds.local && !g.builds.remote && facts.users.guest.home == "tmpfs") (builtins.toJSON g);
  factsHost = expect "host facts" (!facts.nix.localBuilds && facts.nix.remoteBuilds) (builtins.toJSON (removeAttrs facts.nix [ "users" ]));

  # -- deployed type record ---------------------------------------------
  recordSame = T.check "r0k0r" (rec' "admin" "persistent" "admin") (rec' "admin" "persistent" "admin") null;
  recordPromotion = T.check "visitor" (rec' "untrusted" "persistent" "untrusted") (rec' "member" "persistent" "untrusted") null;
  recordAccepted = T.check "visitor" (rec' "member" "persistent" "untrusted") (rec' "untrusted" "persistent" "untrusted") "member->untrusted";
  preSwitchCheck = expect "pre-switch check: visitor admits his accepted predecessor, not admin" (
    lib.hasInfix "'member persistent untrusted'" visitorBlock && !(lib.hasInfix "'admin persistent admin'" visitorBlock)
  ) visitorBlock;
  activationSnippet = expect "activation records after users" (
    c.system.activationScripts.nixos-user-types.deps == [ "users" ]
  ) "deps users";
  realHostRecord = expect "real gb4 records types" (
    off.config.system.preSwitchChecks ? nixos-user-types && off.config.system.activationScripts ? nixos-user-types
  ) "present";

  # The generated shell, whole, for reading and for running by hand against
  # a scratch directory (tests/user-types-eval.sh --scripts prints them).
  scripts = {
    preSwitch = preSwitch;
    activation = c.system.activationScripts.nixos-user-types.text;
    # The handover/kiosk shell, as .drv paths: `nix derivation show <drv>`
    # prints the script (env.text) without building it, for `bash -n`.
    handover =
      let
        pkg = name: (lib.findFirst (p: (p.name or "") == name) (throw "no ${name}") c.environment.systemPackages).drvPath;
      in
      {
        tool = pkg "handover";
        kioskShell = pkg "kiosk-shell-firefox";
        pamCheck = lib.head (
          lib.attrNames (builtins.getContext (lib.last c.security.pam.services.login.rules.account.handover-deadline.args))
        );
      };
  };

  # -- desktop sessions: GNOME for guest and handoff on the real host ----
  gnomeRegistry = expect "registry: guest and handoff have session { desktop = gnome; }" (
    lib.all (n: off.config.my.registry.loaded.effective.${host}.${n}.session == { desktop = "gnome"; }) [ "guest" "handoff" ]
    && off.config.my.users.guest.desktop == "gnome"
    && off.config.my.users.handoff.desktop == "gnome"
    && off.config.my.users.handoff.kiosk == null
    && off.config.my.users.r0k0r.desktop == null
  ) "guest, handoff: gnome; r0k0r: none";
  gnomePins =
    let
      p = off.config.my.internal.sessionPins;
      exe = "${off.config.my.gnome.internal.launcher}/bin/gnome-desktop-session";
    in
    expect "real gb4 pins exactly guest and handoff, greeter-only, to the GNOME launcher" (
      lib.attrNames p == [ "guest" "handoff" ] && lib.all (n: p.${n}.greeterOnly && p.${n}.command == exe) [ "guest" "handoff" ]
    ) (builtins.toJSON (lib.mapAttrs (_: v: v.greeterOnly) p));
  gnomeProfilePin =
    let
      d = builtins.unsafeDiscardStringContext;
      head' = d (lib.head (lib.splitString "__ETC_PROFILE_SOURCED" off.config.environment.etc.profile.text));
      pinOf = uid: builtins.match (".*" + uid + "\\) \\{ IFS= read -r __session_pin_parent < \"/proc/\\$PPID/comm\"; } 2>/dev/null\n +\\[ \"\\$\\{__session_pin_parent-}\" = greetd ] && exec [^ ]+/bin/gnome-desktop-session\n +unset __session_pin_parent ;;.*") head';
    in
    expect "/etc/profile: 1002 and 1003 exec the GNOME launcher only under greetd, before the sourced-once guard; 1000/1001 unpinned" (
      pinOf "1002" != null && pinOf "1003" != null && !(lib.hasInfix "1000)" head') && !(lib.hasInfix "1001)" head')
    ) head';
  gnomeShells = expect "guest and handoff keep a real login shell (no kiosk launcher), nothing in /etc/shells" (
    !(lib.hasInfix "kiosk-shell" (toString (off.config.users.users.guest.shell or "")))
    && !(lib.hasInfix "kiosk-shell" (toString (off.config.users.users.handoff.shell or "")))
    && !(lib.hasInfix "gnome-desktop-session" off.config.environment.etc.shells.text)
  ) "${toString (off.config.users.users.handoff.shell or "default")}";
  gnomeNoKiosk = expect "real gb4: no kiosk launcher, entry or su refusal any more" (
    !(lib.any (p: lib.hasPrefix "kiosk-" (lib.head (p.providedSessions or [ "" ]))) off.config.services.displayManager.sessionPackages)
    && !(off.config.security.pam.services.su.rules.account ? kiosk-pin)
  ) "none";
  gnomeGreeter =
    let
      dm = off.config.services.displayManager.sessionData;
      entry = lib.findFirst (p: p.providedSessions or [ ] == [ "gnome" ]) (throw "no gnome session package") off.config.services.displayManager.sessionPackages;
    in
    expect "greeter: GNOME is a guarded entry of the rebuilt desktops aggregate, after Hyprland, with an ignore-epoch twin" (
      lib.take 2 dm.sessionNames == [ "hyprland" "hyprland-uwsm" ]
      && lib.elem "gnome" dm.sessionNames
      && lib.elem "gnome-ignore-epoch" dm.sessionNames
      # Its block of the aggregate's builder: its files, put in guard mode.
      && lib.any (b: lib.hasPrefix "gnome;" b && lib.hasInfix (builtins.unsafeDiscardStringContext "${entry}") b && lib.hasInfix "put $kind \"$f\" guard" b) (
        lib.splitString "for n in " (builtins.unsafeDiscardStringContext dm.desktops.buildCommand)
      )
      && lib.hasInfix (builtins.unsafeDiscardStringContext "Exec=${off.config.my.gnome.internal.launcher}/bin/gnome-desktop-session") (builtins.unsafeDiscardStringContext entry.text)
    ) (lib.concatStringsSep " " dm.sessionNames);
  gnomeGuardPassThrough =
    let
      t = off.config.my.fallback-session.internal.guardedSession.text or "";
    in
    expect "guarded-session checks only the home-manager accounts: guest and handoff pass through" (
      lib.hasInfix "GUARD_USERS='benjamin r0k0r'" t
    ) (lib.head (lib.filter (lib.hasPrefix "GUARD_USERS") (lib.splitString "
" t)));
  gnomeHandoffTmpfs =
    let
      m = lib.filter (m: m.where == "/home/handoff") off.config.systemd.mounts;
    in
    expect "handoff keeps its tmpfs home bound to user@1003, logind kills only handoff" (
      lib.length m == 1
      && lib.elem "user@1003.service" (lib.head m).requiredBy
      && off.config.services.logind.settings.Login.KillOnlyUsers == "handoff"
    ) (lib.head m).options;
  gnomePasswordless =
    let
      pam = off.config.security.pam.services;
    in
    expect "empty-password login still works: nullok on login (greetd's auth is a substack of login), empty hashes" (
      lib.hasInfix "nullok" pam.login.text
      && (lib.hasInfix "nullok" pam.greetd.text || lib.hasInfix "auth substack login" pam.greetd.text)
      && off.config.users.users.guest.hashedPassword == ""
      && off.config.users.users.handoff.hashedPassword == ""
    ) "nullok";
  gnomeAssertion = expect "a desktop = gnome account on a host without my.gnome fails an assertion" (
    lib.any (a: !a.assertion && lib.hasInfix "needs my.gnome.enable" a.message) noGnome.config.assertions
  ) "refused";

  /*
    GNOME reaches nothing outside its own sessions. Same host, same registry,
    my.gnome on (`off`, the real gb4) and forced off (`noGnome`):
  */
  gnomeEpoch = expect "my.gnome does not move the epoch" (
    off.config.system.build.epoch == noGnome.config.system.build.epoch
  ) off.config.system.build.epoch;
  gnomeEnvironment =
    let
      env = cfg: lib.mapAttrs (_: v: builtins.unsafeDiscardStringContext (toString v)) (
        removeAttrs (cfg.environment.variables // cfg.environment.sessionVariables) [ "XDG_DATA_DIRS" ]
      );
      dirs = cfg: builtins.unsafeDiscardStringContext (toString cfg.environment.sessionVariables.XDG_DATA_DIRS);
      sw = cfg: map (p: builtins.unsafeDiscardStringContext p.name) cfg.environment.systemPackages;
      a = off.config;
      b = noGnome.config;
      # The only move: the greeter's session aggregate ("desktops", which
      # gains gnome.desktop) is one of the XDG_DATA_DIRS entries.
      # (A CA placeholder on gb4, so matched by value, not by name.)
      desktopsOf = cfg: builtins.unsafeDiscardStringContext "${cfg.services.displayManager.sessionData.desktops}/share";
      noDesktops = cfg: lib.filter (e: e != desktopsOf cfg) (lib.splitString ":" (dirs cfg));
      same = {
        variables = env a == env b;
        XDG_DATA_DIRS = noDesktops a == noDesktops b && dirs a != dirs b;
        systemPackages = sw a == sw b;
        extraInit = a.environment.extraInit == b.environment.extraInit;
        pam = lib.mapAttrs (_: s: s.text) a.security.pam.services == lib.mapAttrs (_: s: s.text) b.security.pam.services;
        dbus = map (p: p.name) a.services.dbus.packages == map (p: p.name) b.services.dbus.packages;
        portals = map (p: p.name) a.xdg.portal.extraPortals == map (p: p.name) b.xdg.portal.extraPortals;
        portalConfig = a.xdg.portal.config == b.xdg.portal.config;
        pathsToLink = a.environment.pathsToLink == b.environment.pathsToLink;
        fonts = map (p: p.name) a.fonts.packages == map (p: p.name) b.fonts.packages;
        udev = map (p: p.name) a.services.udev.packages == map (p: p.name) b.services.udev.packages;
      };
      differ = lib.attrNames (lib.filterAttrs (_: v: !v) same);
    in
    expect "my.gnome adds no variable, no system package, no extraInit, no PAM rule, no D-Bus package, no portal, no font, no udev rule" (
      differ == [ ]
    ) "identical${lib.optionalString (differ != [ ]) " except ${toString differ}"}";
  gnomeUserUnits =
    let
      added = lib.subtractLists (lib.attrNames noGnome.config.systemd.user.units) (lib.attrNames off.config.systemd.user.units);
      pkgs' = lib.subtractLists (map (p: p.name) noGnome.config.systemd.packages) (map (p: p.name) off.config.systemd.packages);
    in
    expect "my.gnome adds only GNOME's own (unwanted) user units" (
      lib.all (u: lib.hasPrefix "gnome-session" u) added
      && lib.all (n: lib.any (p: lib.hasPrefix p n) [ "gnome-session-" "gnome-shell-" "gnome-settings-daemon-" "xdg-desktop-portal-gnome-" ]) pkgs'
    ) "units ${toString added}; packages ${toString pkgs'}";
  gnomeHome =
    let
      persist = { my.persist.directories = [ "KSA" ]; };
      h = cfg: ((mkHomeLib host cfg).mkHome { username = "r0k0r"; modules = [ persist ]; }).activationPackage.drvPath;
    in
    expect "r0k0r's home is the same derivation with and without my.gnome" (h off == h noGnome) (h off);

  # -- tuned and untuned accounts (registry/types.nix `tuned`) -----------
  tunedRegistry = expect "tuned = the admins: r0k0r and benjamin on gb4, nobody else" (
    lib.sort lib.lessThan off.config.my.registry.loaded.tuned.${host} == [ "benjamin" "r0k0r" ]
    && lib.sort lib.lessThan reg.tuned.${host} == [ "benjamin" "r0k0r" ]
    && off.config.my.users.r0k0r.tuned
    && off.config.my.users.benjamin.tuned
    && !off.config.my.users.guest.tuned
    && !off.config.my.users.handoff.tuned
    && !c.my.users.visitor.tuned
    && (mkHomeLib host off).facts.tunedUsers == off.config.my.registry.loaded.tuned.${host}
  ) (toString off.config.my.registry.loaded.tuned.${host});
  untunedGnome =
    let
      roots = off.config.my.tuning.untunedRoots;
      # A tuned derivation on gb4 is content-addressed (ca-derivations
      # "tuned"): its output is a placeholder until built. Everything from
      # the untuned set is plain input-addressed upstream.
      tuned = lib.filter (p: !(lib.hasPrefix "/nix/store/" (builtins.unsafeDiscardStringContext p.outPath))) roots;
    in
    expect "GNOME: every untunedRoot (launcher, entry, env, overrides, fonts, user units) is from the untuned set, and the toplevel lists them" (
      tuned == [ ]
      && lib.length roots == 9
      && lib.hasInfix "untuned-roots" off.config.system.extraSystemBuilderCmds
      && off.config.my.gnome.internal.launcher.outPath == (lib.findFirst (p: p.name == "gnome-desktop-session") null roots).outPath
    ) "${toString (map (p: p.name) roots)}${lib.optionalString (tuned != [ ]) "; TUNED: ${toString (map (p: p.name) tuned)}"}";
  untunedHomeDefault =
    let
      h = (mkHomeLib host untunedHome).mkHome {
        username = "visitor";
        # The default itself, without building the untuned set or running the
        # surface check (both below).
        pkgsFor = _: untunedHome.pkgs;
        extraChecks = _: [ ];
      };
      t = h.config.my.tuning;
      r = (mkHomeLib host untunedHome).mkHome { username = "r0k0r"; modules = [ { my.persist.directories = [ "KSA" ]; } ]; pkgsFor = _: untunedHome.pkgs; extraChecks = _: [ ]; };
    in
    expect "an untuned account's standalone home defaults to my.tuning = false; a tuned one's stays \"system\"" (
      t.march == false && t.lto == false && t.o3 == false
      && r.config.my.tuning.march == "system" && r.config.my.tuning.lto == "system"
    ) "visitor ${builtins.toJSON { inherit (t) march lto o3; }}, r0k0r ${builtins.toJSON { inherit (r.config.my.tuning) march lto o3; }}";
  untunedIntegratedRefused = expect "an untuned account with an integrated home fails an assertion" (
    lib.any (a: !a.assertion && lib.hasInfix "visitor is not tuned on this host" a.message) untunedIntegrated.config.assertions
  ) "refused";

  refused = {
    # The untuned default on a march host: refused by the surface check
    # until the perl/sqlite question is decided (lib/home-generator.nix).
    untunedHomeOnMarchHost = mustFail "visitor's untuned home on gb4" (
      ((mkHomeLib host untunedHome).mkHome { username = "visitor"; }).activationPackage.drvPath
    );
    # member -> untrusted without consent: a demotion.
    demotion = mustFail "member->untrusted without acceptTypeChange" (
      T.check "visitor" (rec' "member" "persistent" "untrusted") (rec' "untrusted" "persistent" "untrusted") null
    );
    # persistent -> tmpfs: the on-disk home would vanish under a tmpfs.
    persistentToTmpfs = mustFail "persistent->tmpfs" (
      T.check "guest" (rec' "handover" "persistent" "none") (rec' "handover" "tmpfs" "none") null
    );
    # Consent names one transition, not any.
    wrongConsent = mustFail "admin->untrusted with member->untrusted consent" (
      T.check "visitor" (rec' "admin" "persistent" "admin") (rec' "untrusted" "persistent" "untrusted") "member->untrusted"
    );
    # Nix has no per-user max-jobs: victus-15 builds locally for everyone.
    localBuildsOnBuilder = mustFail "narrow.localBuilds on victus-15" (
      (regWith (
        r:
        r
        // {
          hosts = r.hosts // {
            hosts = r.hosts.hosts // {
              victus-15 = r.hosts.hosts.victus-15 // {
                users = r.hosts.hosts.victus-15.users ++ [ "visitor" ];
                narrow.visitor.localBuilds = false;
              };
            };
          };
        }
      )).effective.victus-15.visitor
    );
    # home = impermanent exists now (features/core/impermanence), but only
    # where the host's registry facts declare it: refused on victus-15.
    impermanent = mustFail "home = impermanent on a host without impermanence" (
      (regWith (
        r:
        r
        // {
          users = r.users // { visitor = r.users.visitor // { overrides.home = "impermanent"; }; };
          hosts = r.hosts // {
            hosts = r.hosts.hosts // {
              victus-15 = r.hosts.hosts.victus-15 // { users = r.hosts.hosts.victus-15.users ++ [ "visitor" ]; };
            };
          };
        }
      )).effective.victus-15.visitor
    );
    # Narrowing keeps less, never more: tmpfs -> impermanent widens the
    # handover guest's home, impermanent -> persistent widens an
    # impermanent user's.
    narrowWidenTmpfs = mustFail "narrow.guest.home = impermanent (tmpfs keeps less)" (
      (regWith (r: r // { hosts = r.hosts // { hosts = r.hosts.hosts // { ${host} = r.hosts.hosts.${host} // { narrow = r.hosts.hosts.${host}.narrow // { guest.home = "impermanent"; }; }; }; }; })).effective.${host}.guest
    );
    narrowWidenImpermanent = mustFail "narrow.visitor.home = persistent over an impermanent visitor" (
      (regWith (
        r:
        r
        // {
          users = r.users // { visitor = r.users.visitor // { overrides.home = "impermanent"; }; };
          hosts = r.hosts // { hosts = r.hosts.hosts // { ${host} = r.hosts.hosts.${host} // { narrow = r.hosts.hosts.${host}.narrow // { visitor = r.hosts.hosts.${host}.narrow.visitor // { home = "persistent"; }; }; }; }; };
        }
      )).effective.${host}.visitor
    );
    # Only a home-manager session has a home to activate.
    standaloneKiosk = mustFail "homeActivation = standalone on a kiosk user" (
      lib.attrNames
        ((regWith (r: r // { users = r.users // { guest = r.users.guest // { homeActivation = "standalone"; }; }; })).materialize host on.pkgs)
        .guest
    );
    # Groups are derived; a hand-written list is refused, not merged.
    handGroups = mustFail "groups in a user file" (
      lib.attrNames
        ((regWith (r: r // { users = r.users // { visitor = r.users.visitor // { groups = [ "wheel" ]; }; }; })).materialize host on.pkgs)
        .visitor
    );
    # A handover password is issued per lending, never declared.
    handoverSecret = mustFail "passwordSecret on a handover account" (
      (regWith (r: r // { users = r.users // { guest = r.users.guest // { passwordSecret = ./user-types.nix; }; }; })).check
    );
    handoverOnOtherType = mustFail "handover key on an untrusted account" (
      (regWith (r: r // { users = r.users // { visitor = r.users.visitor // { handover = { }; }; }; })).check
    );
    handoverExpires = mustFail "handover.expires = \"next week\"" (
      (regWith (r: r // { users = r.users // { guest = r.users.guest // { handover.expires = "next week"; }; }; })).check
    );
    # Pinned: no shell of its own, no ssh.
    kioskSshKeys = mustFail "sshKeys on a kiosk account" (
      lib.attrNames
        ((regWith (r: r // { users = r.users // { guest = r.users.guest // { sshKeys = [ "ssh-ed25519 AAAA" ]; }; }; })).materialize host on.pkgs)
        .guest
    );
    # Desktops are a closed list (lib/registry.nix axisValues.desktop).
    unknownDesktop = mustFail "session = { desktop = \"kde\"; }" (
      (regWith (r: r // { users = r.users // { visitor = r.users.visitor // { overrides.session = { desktop = "kde"; }; }; }; })).effective.${host}.visitor
    );
    desktopExtraKey = mustFail "session = { desktop = \"gnome\"; kiosk = \"firefox\"; }" (
      (regWith (r: r // { users = r.users // { visitor = r.users.visitor // { overrides.session = { desktop = "gnome"; kiosk = "firefox"; }; }; }; })).effective.${host}.visitor
    );
    tmpfsSize = mustFail "tmpfsSize = 2 gigs" (
      (regWith (r: r // { users = r.users // { guest = r.users.guest // { tmpfsSize = "2 gigs"; }; }; })).check
    );
  };
}
