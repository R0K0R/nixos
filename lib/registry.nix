/*
  The user registry's rules: preset merge, override policy, contradictions, uid
  bookkeeping. Pure -- `lib` in, data out, no `pkgs`, no `config` -- so the same
  answer is available to mkHost, to tier2-eval's throwaway pass1, to homeLib's
  facts, and to `nix eval .#registry` without evaluating any machine.

  WHY THE DATA LIVES OUTSIDE THE MODULE SYSTEM. `my.users` used to be written by
  hand in each host file, so "who is r0k0r" had one answer per host and nothing
  compared them: galaxybook and victus-15 each carried their own copy of the
  same password secret, the same shell, the same primary flag. A person is a
  flake-level fact; a host only says which people live on it. Keeping that as
  plain data (registry/) means a user's standalone home repo can read it through
  homeLib without importing a NixOS evaluation, and a consistency error is a
  `throw` with the file name in it instead of a module-system trace.

  WHY THROW, NOT ASSERTIONS. Assertions only fire when someone forces the
  toplevel, and only for the host being built. A uid collision between a user
  who lives on victus-15 and a tombstone nobody references anywhere is still a
  collision -- the uid comes back on the next host that adds the name -- so the
  global checks below run whenever ANY host reads the registry.

  AXES AND THEIR MACHINERY. home = "tmpfs", nix = "none" / "untrusted", kiosk
  sessions (pinned: whatever the greeter asks for, the login gets the one
  program) and with them the handover and untrusted types are implemented
  (features/core/users: tmpfs-home.nix, kiosk.nix, nix-access.nix). The
  handover TYPE also carries its credentials -- not an axis, a property of
  lending: a passphrase issued per lending with a deadline, and an optional
  `handover.expires` ceiling in the user file (handover.nix).
  home = "impermanent" is features/core/impermanence: the home is wiped with
  the root at every boot and rebuilt from the user's own persist list merged
  with the features' (accepted on a host whose facts declare impermanence).
  nix = "overlay" is features/nix/guest-overlay, accepted on a host whose
  registry facts declare it. The refusal is what stops a host
  from silently getting a persistent home while the registry says otherwise.
  `grants` become groups through `grantGroups` below.

  WHAT NIX CAN AND CANNOT ENFORCE PER USER. The daemon knows exactly two
  per-user lists: allowed-users (may connect at all) and trusted-users (may
  pass privileged settings: --builders, substituters, max-jobs, ...).
  Everything else -- max-jobs, the builders in /etc/nix/machines -- is a
  DAEMON setting applied to every build it accepts, whoever asked. So:

    nix = "none"       enforceable: not in allowed-users.
    nix = "untrusted"  enforceable: not in trusted-users. The user still gets
                       builds, with the HOST's max-jobs and, on a builder
                       client, the host's remote builders -- the daemon
                       dispatches for him, he just cannot pick them.
    nix = "admin"      trusted-users is DERIVED from it (nix-access.nix):
                       exactly the host's nix = "admin" accounts, plus
                       root (NixOS) and my.registry.nix.extraTrustedUsers.
    builders = false   enforceable only as "cannot name builders of his own"
                       (that needs trust). It does NOT keep his builds off the
                       daemon's builders; `nixFacts` says where they go.
    localBuilds narrowing (hosts.nix narrow.<user>.localBuilds = false)
                       there is no per-user max-jobs, so it is accepted only
                       where it is already true: the host builds nothing
                       locally for anyone (features.<host>.localBuilds = false,
                       i.e. max-jobs = 0, galaxybook's no-local-builds rule)
                       or the user has no daemon access. Anywhere else it is
                       refused rather than recorded as a promise nothing keeps.

  `nixFacts` is that honest version, per host and user, for homeLib facts.

  TYPE TRANSITIONS. A type is not only a preset, it is a promise about what
  is on disk: a persistent home, a nix profile. `transition` decides whether
  moving a user from a recorded (deployed) type to the current one is safe;
  features/core/users/type-record.nix records the deployed type per user and
  refuses the unsafe moves at switch time unless the user file carries the
  matching `acceptTypeChange = "<old type>-><new type>"`.
*/
{ lib }:

let
  inherit (lib)
    attrNames
    concatMapStringsSep
    concatStringsSep
    elem
    filter
    filterAttrs
    isAttrs
    isBool
    isList
    isString
    mapAttrs
    subtractLists
    ;

  axisValues = {
    home = [ "persistent" "tmpfs" "impermanent" ];
    # Ordered by how much of the store a user may touch -- the order narrowing
    # walks. overlay sits below untrusted: an overlay user writes only to a
    # private upper store, an untrusted one to the shared daemon.
    nix = [ "none" "overlay" "untrusted" "admin" ];
    grants = [ "sudo" "network" "media" "serial" "input" ];
  };

  /*
    What each grant IS on a NixOS host. An account's extraGroups are exactly
    these, in axisValues.grants order -- nothing else names groups for people
    (features may still add accounts to their own groups, e.g. input for an
    input daemon). Before this, a user without a hand-written group list got
    my.users' default, which includes wheel: sudo for anyone, a handover
    guest included.
  */
  grantGroups = {
    sudo = [ "wheel" ];
    network = [ "networkmanager" ];
    media = [ "video" "audio" ];
    serial = [ "dialout" ];
    input = [ "input" ];
  };
  axes = [ "home" "nix" "session" "builders" "grants" ];

  rank = v: lib.lists.findFirstIndex (x: x == v) null axisValues.nix;
  # home values by how much survives a reboot, least first (see `narrow`).
  homePersistence = [ "tmpfs" "impermanent" "persistent" ];
  persistRank = v: lib.lists.findFirstIndex (x: x == v) null homePersistence;

  sessionKind =
    s:
    if s == "home-manager" || s == "system-default" then
      s
    else if isAttrs s && attrNames s == [ "kiosk" ] && isString s.kiosk then
      "kiosk"
    else
      null;

  fmtList = concatMapStringsSep ", " (x: if isString x then x else builtins.toJSON x);

  # One axis value, checked against its domain. `where` names the file so the
  # message points at the line to fix.
  checkAxis =
    where: axis: v:
    if axis == "session" then
      (if sessionKind v != null then v else throw ''
        registry: ${where}: session must be "home-manager", "system-default" or
        { kiosk = "<attribute name of a package>"; }, got ${builtins.toJSON v}'')
    else if axis == "builders" then
      (if isBool v then v else throw "registry: ${where}: builders must be a bool, got ${builtins.toJSON v}")
    else if axis == "grants" then
      (
        if isList v && subtractLists axisValues.grants v == [ ] then
          v
        else
          throw ''
            registry: ${where}: grants must be a list drawn from [ ${fmtList axisValues.grants} ],
            got ${builtins.toJSON v}''
      )
    else if elem v axisValues.${axis} then
      v
    else
      throw "registry: ${where}: ${axis} must be one of [ ${fmtList axisValues.${axis}} ], got ${builtins.toJSON v}";

  /*
    A type preset plus a user's overrides -> the user's effective axes.

    Overrides outside the type's `overridable` list are refused rather than
    ignored: "member, but nix = admin" is a different type wearing a member
    label, and the label is what someone reading registry/users/ trusts.
  */
  effectiveAxes =
    types: name: u:
    let
      where = "registry/users/${name}.nix";
      t =
        types.${u.type} or (throw ''
          registry: ${where}: type "${toString (u.type or "<missing>")}" is not defined in
          registry/types.nix (have: ${fmtList (attrNames types)})'');
      ov = u.overrides or { };
      unknown = subtractLists axes (attrNames ov);
      forbidden = subtractLists t.overridable (attrNames ov);
      merged = mapAttrs (axis: _: checkAxis where axis (ov.${axis} or t.${axis})) (lib.genAttrs axes (_: null));
    in
    if unknown != [ ] then
      throw "registry: ${where}: overrides name unknown axes: ${fmtList unknown} (axes: ${fmtList axes})"
    else if forbidden != [ ] then
      throw ''
        registry: ${where}: type "${u.type}" does not allow overriding ${fmtList forbidden}
        (overridable for ${u.type}: ${if t.overridable == [ ] then "nothing" else fmtList t.overridable}).
        Pick a type whose preset already says what you mean.''
    else
      merged;

  /*
    Contradictions between axes, and between a user and the host they are on.
    Each is a combination that would evaluate and then not work:

      session = home-manager, nix = none
        home-manager activation is a nix build of the user's generation and a
        profile write; with no daemon access it fails at first login.
      nix = overlay, host without guest-overlay
        there is no overlay store on that host to put the user in.
      builders, nix neither admin nor overlay
        dispatching to remote builders needs trusted-user rights (--builders,
        substituters) on the shared daemon; an untrusted/none user asking for it
        is a request the daemon will silently refuse. An overlay user owns a
        store of their own and may name any builders there.
  */
  contradictions =
    where: hostFeatures: e:
    if e.session == "home-manager" && e.nix == "none" then
      throw ''
        registry: ${where}: session = "home-manager" needs nix access, but nix = "none".
        Give the user nix = "untrusted" (or "overlay"), or session = "system-default".''
    else if e.home == "impermanent" && !(hostFeatures.impermanence or false) then
      throw ''
        registry: ${where}: home = "impermanent" but the host does not declare the impermanence
        feature in registry/hosts.nix (features.<host>.impermanence).''
    else if e.nix == "overlay" && !(hostFeatures."guest-overlay" or false) then
      throw ''
        registry: ${where}: nix = "overlay" but the host does not declare the guest-overlay
        feature in registry/hosts.nix (features.<host>."guest-overlay").''
    else if e.builders && !(elem e.nix [ "admin" "overlay" ]) then
      throw ''
        registry: ${where}: builders = true needs nix = "admin" (trusted-user rights to
        dispatch builds) or "overlay" (their own store), but nix = "${e.nix}".''
    else
      e;

  /*
    Hosts may NARROW a user's axes, never widen them: a laptop can say "benjamin
    gets no builders here", but no host can make a member an admin -- that is a
    type change, and it belongs in the user's own file where it is visible.
  */
  narrow =
    where: e: n:
    let
      /*
        home narrows by what survives a reboot: a persistent home keeps
        everything, an impermanent one only its persist manifest, a tmpfs one
        nothing. So a host may make a persistent user impermanent there (the
        machine's root is wiped; galaxybook4-pro360) without that leaking to
        every other host the user lives on, as a user-file override would.
      */
      bad =
        filter (axis: !(
          if axis == "builders" then
            isBool n.builders && (n.builders -> e.builders)
          else if axis == "grants" then
            isList n.grants && subtractLists e.grants n.grants == [ ]
          else if axis == "nix" then
            rank n.nix != null && rank n.nix <= rank e.nix
          else if axis == "home" then
            persistRank n.home != null && persistRank n.home <= persistRank e.home
          else
            false
        )) (attrNames n);
    in
    if bad != [ ] then
      throw ''
        registry: ${where}: narrow.${fmtList bad} would widen or is not narrowable
        (narrowable: builders true->false, grants to a subset, nix to a lower rank of
        [ ${fmtList axisValues.nix} ], home to one that keeps less of
        [ ${fmtList homePersistence} ]).''
    else
      e // n;

  /*
    narrow.<user>.localBuilds = false: "nothing builds on this machine's CPU
    for this user". Nix has no per-user max-jobs, so the only honest way to
    accept it is where it already holds -- see the header. Not an axis (types
    have no say in it, it is a property of the host's daemon) and therefore
    stripped before `narrow`, which only knows axes.
  */
  checkLocalBuilds =
    where: hostFeatures: e: n:
    if !(n ? localBuilds) then
      e
    else if n.localBuilds != false then
      throw "registry: ${where}: narrow.localBuilds can only be false (hosts narrow, never widen)"
    else if elem e.nix [ "untrusted" "admin" ] && (hostFeatures.localBuilds or true) then
      throw ''
        registry: ${where}: narrow.localBuilds = false cannot be enforced here. Nix has no
        per-user max-jobs: the daemon builds for every user it accepts, with the host's own
        max-jobs. Either make it a host policy (max-jobs = 0 and features.<host>.localBuilds
        = false in registry/hosts.nix, as on galaxybook4-pro360), or narrow nix to "none"
        for this user.''
    else
      e;

  checkUids =
    users:
    let
      byUid = lib.groupBy (n: toString users.${n}.uid) (attrNames users);
      dups = filterAttrs (_: ns: builtins.length ns > 1) byUid;
      bad = filter (n: !(builtins.isInt (users.${n}.uid or null)) || users.${n}.uid < 1000) (attrNames users);
    in
    if bad != [ ] then
      throw "registry: users ${fmtList bad} need an integer uid >= 1000 (tombstones too: removed = true keeps its uid)"
    else if dups != { } then
      throw (
        "registry: uid reused -- "
        + concatStringsSep "; " (lib.mapAttrsToList (uid: ns: "${uid} by ${fmtList ns}") dups)
        + ". uids are never reused, not even a removed user's (tombstone): files on disk"
        + " and in backups still carry the old owner's number."
      )
    else
      true;
in
{
  inherit axisValues axes;

  /*
    users  : name -> registry/users/<name>.nix
    types  : registry/types.nix
    hosts  : registry/hosts.nix
  */
  load =
    {
      users,
      types,
      hosts,
    }:
    let
      live = filterAttrs (_: u: !(u.removed or false)) users;

      globalOk =
        checkUids users
        && lib.all (
          n:
          let
            u = users.${n};
            where = "registry/users/${n}.nix";
          in
          (
            !(u ? tmpfsSize)
            || (isString u.tmpfsSize && builtins.match "[1-9][0-9]*[kKmMgG%]?" u.tmpfsSize != null)
            || throw "registry: ${where}: tmpfsSize must be a tmpfs size= value like \"2G\" or \"25%\", got ${builtins.toJSON u.tmpfsSize}"
          )
          && (
            !(u ? handover)
            || (
              (u.type or null) == "handover"
              || throw "registry: ${where}: `handover` is only for type = \"handover\" accounts"
            )
            && (
              isAttrs u.handover
              && subtractLists [ "expires" ] (attrNames u.handover) == [ ]
              && (!(u.handover ? expires) || isString u.handover.expires && builtins.match "[0-9]{4}-[0-9]{2}-[0-9]{2}" u.handover.expires != null)
              || throw "registry: ${where}: handover must be { expires = \"YYYY-MM-DD\"; } (or {}), got ${builtins.toJSON u.handover}"
            )
          )
          && (
            (u.type or null) != "handover"
            || !(u ? passwordSecret)
            || throw ''
              registry: ${where}: a handover account has no fixed password -- an admin issues one
              per lending on the machine (`sudo handover issue ${n}`). Drop passwordSecret.''
          )
          && (
            !(u ? acceptTypeChange)
            || (isString u.acceptTypeChange && builtins.match "[a-z0-9-]+->[a-z0-9-]+" u.acceptTypeChange != null)
            || throw "registry: ${where}: acceptTypeChange must be \"<old type>-><new type>\", got ${builtins.toJSON u.acceptTypeChange}"
          )
        ) (attrNames users)
        # Every type is checked even when no user has it, so a broken preset is
        # caught the day it is written, not the day someone is given it.
        && lib.all (
          tn:
          let
            t = types.${tn};
            e = effectiveAxes types "<preset ${tn}>" { type = tn; };
          in
          builtins.seq (mapAttrs (_: _: null) e) (
            (
              subtractLists axes t.overridable == [ ]
              || throw "registry/types.nix: ${tn}.overridable names unknown axes: ${fmtList (subtractLists axes t.overridable)}"
            )
            && (builtins.isInt (t.rank or null) || throw "registry/types.nix: ${tn}.rank must be an integer (demotion order, see the header there)")
          )
        ) (attrNames types)
        && lib.all (
          hn:
          let
            h = hosts.hosts.${hn};
            missing = filter (n: !(users ? ${n})) h.users;
            dead = filter (n: users ? ${n} && (users.${n}.removed or false)) h.users;
          in
          if missing != [ ] then
            throw "registry/hosts.nix: ${hn} lists users with no registry/users/<name>.nix: ${fmtList missing}"
          else if dead != [ ] then
            throw "registry/hosts.nix: ${hn} lists removed (tombstoned) users: ${fmtList dead}"
          else if subtractLists h.users (h.localPasswords or [ ]) != [ ] then
            throw "registry/hosts.nix: ${hn}.localPasswords names accounts that do not live there: ${fmtList (subtractLists h.users (h.localPasswords or [ ]))}"
          else if !(elem h.primary h.users) then
            throw "registry/hosts.nix: ${hn}.primary = \"${h.primary}\" is not one of its users"
          else
            true
        ) (attrNames hosts.hosts);

      guard = v: builtins.seq globalOk v;

      # host -> user -> effective axes, after host narrowing and contradiction checks.
      effective = mapAttrs (
        hn: h:
        lib.genAttrs h.users (
          n:
          let
            where = "user ${n} on host ${hn}";
            f = hosts.features.${hn} or { };
            nw = h.narrow.${n} or { };
            e0 = effectiveAxes types n users.${n};
            e1 = narrow where e0 (removeAttrs nw [ "localBuilds" ]);
          in
          guard (checkLocalBuilds where f (contradictions where f e1) nw)
        )
      ) hosts.hosts;

      /*
        host -> user -> what the nix daemon actually does for this user (see
        the header: what Nix can and cannot enforce per user). Unmanaged or
        unlisted host facts default to the daemon's own defaults: local builds
        on, no remote builders.
      */
      nixFacts = mapAttrs (
        hn: h:
        let
          f = hosts.features.${hn} or { };
        in
        lib.genAttrs h.users (
          n:
          let
            e = effective.${hn}.${n};
            daemon = elem e.nix [ "untrusted" "admin" ];
            own = e.nix == "overlay";
          in
          {
            access = e.nix;
            inherit daemon;
            trusted = e.nix == "admin";
            # "shared": the system's store via the daemon. "own": a private
            # overlay store (features/nix/guest-overlay), opened directly.
            store = if own then "own" else if daemon then "shared" else "none";
            builds = {
              # An overlay guest's default max-jobs follows the host policy too.
              local = (daemon || own) && (f.localBuilds or true);
              # The daemon's builders, dispatched for anyone it accepts. An
              # overlay guest has none but their own.
              remote = daemon && (f.builderClient or false);
            };
            # May name builders/substituters of its own: trusted-user rights on
            # the shared daemon, or simply owning the store.
            ownBuilders = e.builders || own;
          }
        )
      ) hosts.hosts;

      /*
        Deployed type -> current type. A record is { type, home, nix }; the
        three things whose change can strand data or break a login:

          home persistent -> anything else
            the on-disk home is hidden under a tmpfs (or wiped at boot). Not
            deleted, but unreachable for that user from then on.
          nix to a lower rank
            profiles, home-manager generations, gcroots the user relies on
            stop being usable (none: the daemon refuses him outright).
          type to a lower rank (registry/types.nix `rank`)
            a demotion, even where the axes happen to stay put -- member ->
            untrusted with nix overridden back to "untrusted" still drops the
            home-manager session and the grants.

        An unknown recorded type or axis value (a type since renamed, a
        hand-edited file) counts as dangerous: there is nothing to compare.
      */
      transition =
        let
          rankIn = list: v: lib.lists.findFirstIndex (x: x == v) null list;
          typeRank = t: types.${t}.rank or null;
          lower = a: b: a == null || b == null || a < b;
          reasonsFor =
            old: new:
            lib.optional (
              old.home != new.home && (new.home == "tmpfs" || old.home == "persistent")
            ) "home ${old.home} -> ${new.home} hides the existing home"
            ++ lib.optional (lower (rankIn axisValues.nix new.nix) (rankIn axisValues.nix old.nix)) "nix ${old.nix} -> ${new.nix} loses store access"
            ++ lib.optional (lower (typeRank new.type) (typeRank old.type)) "type ${old.type} -> ${new.type} is a demotion";
          label = old: new: "${old.type}->${new.type}";
          domain = lib.concatMap (
            t: lib.concatMap (hm: map (x: { type = t; home = hm; nix = x; }) axisValues.nix) axisValues.home
          ) (attrNames types);
          fmt = r: "${r.type} ${r.home} ${r.nix}";
        in
        rec {
          recordOf = type: e: { inherit type; inherit (e) home nix; };
          inherit fmt label;
          /*
            "same" | "safe" | "accepted" | { refused = [ reasons ]; }
            `accept` is the user file's acceptTypeChange (or null).
          */
          verdict =
            old: new: accept:
            let
              rs = reasonsFor old new;
            in
            if old == new then
              "same"
            else if rs == [ ] then
              "safe"
            else if accept == label old new then
              "accepted"
            else
              { refused = rs; };
          /*
            The same rule as a throw, for evaluation-time use (tests, a
            `nix eval` before a switch).
          */
          check =
            who: old: new: accept:
            let
              v = verdict old new accept;
            in
            if builtins.isString v then
              v
            else
              throw ''
                registry: user ${who}: deployed as ${fmt old}, now ${fmt new}: ${concatStringsSep "; " v.refused}.
                Add acceptTypeChange = "${label old new}"; to registry/users/${who}.nix to do it anyway.'';
          /*
            Every recorded state the CURRENT record may follow without a
            refusal -- what type-record.nix bakes into its shell check, so
            the rule above is the only copy of the rule.
          */
          admissible = new: accept: map fmt (lib.filter (old: builtins.isString (verdict old new accept)) domain);
        };

      notYet =
        where: what:
        throw "registry: ${where}: ${what} is not implemented yet -- the registry accepts it, but no machinery exists to give it to you. See lib/registry.nix.";

      /*
        Effective axes -> the my.users entry features/users consumes. Only the
        axes that already have machinery are allowed through; everything else
        is refused here rather than approximated.

        `uid` is pinned for every account. Both hosts' accounts were created
        unpinned; the registry uids were checked against the live ones (r0k0r
        1000 on both, benjamin 1001 on victus-15, 2026-10-17) before turning
        this on, so the first switch only rewrites users-groups.json -- no
        file on disk changes owner. A NEW user's uid comes from his file, never
        from declaration order.
      */
      materialize =
        hn: pkgs:
        let
          h = hosts.hosts.${hn};
        in
        guard (
          lib.genAttrs h.users (
            n:
            let
              u = users.${n};
              e = effective.${hn}.${n};
              where = "user ${n} on host ${hn}";
              groups = lib.concatMap (g: grantGroups.${g}) (lib.filter (g: elem g e.grants) axisValues.grants);
            in
            if e.nix == "overlay" && e.session == "home-manager" && (u.homeActivation or "system") != "standalone" then
              throw ''
                registry: ${where}: nix = "overlay" with a home-manager session needs
                homeActivation = "standalone": the system cannot activate a home that lives
                in the guest's own store.''
            else if sessionKind e.session == "kiosk" && !(pkgs ? ${e.session.kiosk}) then
              throw "registry: ${where}: session.kiosk = \"${e.session.kiosk}\" is not a package attribute of this host's pkgs"
            else if sessionKind e.session == "kiosk" && (u ? shell || (u.sshKeys or [ ]) != [ ]) then
              throw ''
                registry: ${where}: a kiosk session pins the login shell to the kiosk launcher and
                refuses ssh (features/core/users/kiosk.nix); drop `shell` and `sshKeys`.''
            else if (u.homeActivation or "system") == "standalone" && e.session != "home-manager" then
              throw ''
                registry: ${where}: homeActivation = "standalone" but session is ${builtins.toJSON e.session}.
                Only a home-manager session has a home to activate.''
            else if u ? groups || h ? groups then
              throw ''
                registry: ${where}: `groups` is gone -- groups are derived from grants
                (lib/registry.nix grantGroups). Say grants (overrides.grants in the user file,
                narrow.<user>.grants in hosts.nix) instead.''
            else
              {
                inherit (u) uid;
                primary = n == h.primary;
                home = e.session == "home-manager";
                # Consumed only by assertions, mkIf-gated settings and the
                # opt-in type record, so passing them for every user moves
                # nothing on a host whose users are all persistent admins
                # and members.
                inherit (e) nix;
                typeRecord =
                  let
                    r = transition.recordOf u.type e;
                    accept = u.acceptTypeChange or null;
                  in
                  {
                    current = transition.fmt r;
                    admissible = transition.admissible r accept;
                    inherit accept;
                  };
              }
              // lib.optionalAttrs (e.home == "tmpfs") { tmpfsHome.size = u.tmpfsSize or "2G"; }
              // lib.optionalAttrs (e.home == "impermanent") { impermanentHome = true; }
              // lib.optionalAttrs (sessionKind e.session == "kiosk") { kiosk = pkgs.${e.session.kiosk}; }
              // lib.optionalAttrs (u.type == "handover") { handover.expires = u.handover.expires or null; }
              // lib.optionalAttrs (u ? description) { inherit (u) description; }
              # A host that keeps an account's password local (hosts.nix
              # localPasswords) does not get the registry's secret for it.
              // lib.optionalAttrs (u ? passwordSecret && !(elem n (h.localPasswords or [ ]))) { inherit (u) passwordSecret; }
              // lib.optionalAttrs (u ? sshKeys) { inherit (u) sshKeys; }
              // lib.optionalAttrs (u ? homeActivation) { inherit (u) homeActivation; }
              // lib.optionalAttrs (u ? stateVersion) { inherit (u) stateVersion; }
              // lib.optionalAttrs (u ? shell) { shell = pkgs.${u.shell}; }
              // { extraGroups = groups; }
          )
        );
    in
    {
      inherit
        users
        live
        types
        hosts
        effective
        nixFacts
        transition
        materialize
        ;
      check = globalOk;
    };
}
