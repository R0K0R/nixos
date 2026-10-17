/*
  The handover and untrusted user types, and the deployed-type record, on a
  synthetic copy of galaxybook4-pro360. No real host has such a user (and
  none records types), so this is the only place that machinery is
  evaluated.

  The synthetic registry (my.registry.extend) adds two accounts to gb4:

    guest    handover: tmpfs home (1G), nix = none, kiosk firefox
    visitor  untrusted, with nix overridden to "untrusted" and
             narrow.localBuilds = false (true anyway on gb4, max-jobs = 0),
             acceptTypeChange = "member->untrusted"

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
            users = raw.hosts.hosts.${host}.users ++ [ "guest" "visitor" ];
            narrow.visitor.localBuilds = false;
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
  realHostLogind = expect "real gb4 logind untouched" (
    !off.config.services.logind.settings.Login.KillUserProcesses && !(off.config.services.logind.settings.Login ? KillOnlyUsers)
  ) "KillUserProcesses=no";

  # -- kiosk session -----------------------------------------------------
  sessions = expect "kiosk-firefox offered" (lib.elem "kiosk-firefox" sessionNames) (toString sessionNames);
  kioskSession = kioskEntry.drvPath;
  kioskOnce = expect "one kiosk entry" (lib.length (lib.filter (lib.hasPrefix "kiosk-") sessionNames) == 1) (toString sessionNames);

  # -- nix access --------------------------------------------------------
  allowedUsers = expect "allowed-users excludes guest" (
    c.nix.settings.allowed-users == [ "root" "r0k0r" "visitor" ]
  ) (toString c.nix.settings.allowed-users);
  realHostAllowedUsers = expect "real gb4 keeps allowed-users = *" (off.config.nix.settings.allowed-users == [ "*" ]) (
    toString off.config.nix.settings.allowed-users
  );
  nixConf = expect "nix.conf differs from the real host's" (
    c.environment.etc."nix/nix.conf".source.drvPath != off.config.environment.etc."nix/nix.conf".source.drvPath
  ) c.environment.etc."nix/nix.conf".source.drvPath;
  trustedUsers = expect "trusted-users = root + the nix = admin accounts" (c.nix.settings.trusted-users == [ "root" "r0k0r" ]) (
    toString c.nix.settings.trusted-users
  );
  trustedByHandCaught = expect "extraTrustedUsers naming visitor fails an assertion" (
    lib.any (a: !a.assertion && lib.hasInfix "my.users.visitor " a.message) trustedByHand.config.assertions
  ) (toString trustedByHand.config.nix.settings.trusted-users);

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
  realHostNoRecord = expect "real gb4 has no type record" (
    !(off.config.system.preSwitchChecks ? nixos-user-types) && !(off.config.system.activationScripts ? nixos-user-types)
  ) "absent";

  # The generated shell, whole, for reading and for running by hand against
  # a scratch directory (tests/user-types-eval.sh --scripts prints them).
  scripts = {
    preSwitch = preSwitch;
    activation = c.system.activationScripts.nixos-user-types.text;
  };

  refused = {
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
    # Still without machinery.
    impermanent = mustFail "home = impermanent" (
      # attrNames, not the entry: the entry holds packages, and deepSeq
      # into a package set overflows instead of throwing.
      lib.attrNames
        ((regWith (r: r // { users = r.users // { visitor = r.users.visitor // { overrides.home = "impermanent"; }; }; })).materialize
          host
          on.pkgs
        ).visitor
    );
    tmpfsSize = mustFail "tmpfsSize = 2 gigs" (
      (regWith (r: r // { users = r.users // { guest = r.users.guest // { tmpfsSize = "2 gigs"; }; }; })).check
    );
  };
}
