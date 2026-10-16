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

  AXES WITHOUT MACHINERY. tmpfs/impermanent homes, overlay stores, nix=none,
  kiosk sessions and the handover type are validated here (so the data format
  is settled and contradictions are caught now) but `materialize` refuses them
  with "not implemented yet". No host uses them today; the refusal is what stops
  one from silently getting a persistent home while the registry says tmpfs.
  `builders` and `grants` are validated and exposed as facts but have no effect
  on the system yet either; see the TODOs in registry/types.nix.
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
  axes = [ "home" "nix" "session" "builders" "grants" ];

  rank = v: lib.lists.findFirstIndex (x: x == v) null axisValues.nix;

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
      builders, nix not admin
        dispatching to remote builders needs trusted-user rights (--builders,
        substituters); an untrusted/overlay/none user asking for it is a request
        the daemon will silently refuse.
  */
  contradictions =
    where: hostFeatures: e:
    if e.session == "home-manager" && e.nix == "none" then
      throw ''
        registry: ${where}: session = "home-manager" needs nix access, but nix = "none".
        Give the user nix = "untrusted" (or "overlay"), or session = "system-default".''
    else if e.nix == "overlay" && !(hostFeatures."guest-overlay" or false) then
      throw ''
        registry: ${where}: nix = "overlay" but the host does not declare the guest-overlay
        feature in registry/hosts.nix (features.<host>."guest-overlay").''
    else if e.builders && e.nix != "admin" then
      throw ''
        registry: ${where}: builders = true needs nix = "admin" (trusted-user rights to
        dispatch builds), but nix = "${e.nix}".''
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
      bad =
        filter (axis: !(
          if axis == "builders" then
            isBool n.builders && (n.builders -> e.builders)
          else if axis == "grants" then
            isList n.grants && subtractLists e.grants n.grants == [ ]
          else if axis == "nix" then
            rank n.nix != null && rank n.nix <= rank e.nix
          else
            false
        )) (attrNames n);
    in
    if bad != [ ] then
      throw ''
        registry: ${where}: narrow.${fmtList bad} would widen or is not narrowable
        (narrowable: builders true->false, grants to a subset, nix to a lower rank of
        [ ${fmtList axisValues.nix} ]).''
    else
      e // n;

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
        # Every type is checked even when no user has it, so a broken preset is
        # caught the day it is written, not the day someone is given it.
        && lib.all (
          tn:
          let
            t = types.${tn};
            e = effectiveAxes types "<preset ${tn}>" { type = tn; };
          in
          builtins.seq (mapAttrs (_: _: null) e) (
            subtractLists axes t.overridable == [ ]
            || throw "registry/types.nix: ${tn}.overridable names unknown axes: ${fmtList (subtractLists axes t.overridable)}"
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
            e0 = effectiveAxes types n users.${n};
            e1 = narrow where e0 (h.narrow.${n} or { });
          in
          guard (contradictions where (hosts.features.${hn} or { }) e1)
        )
      ) hosts.hosts;

      notYet =
        where: what:
        throw "registry: ${where}: ${what} is not implemented yet -- the registry accepts it, but no machinery exists to give it to you. See lib/registry.nix.";

      /*
        Effective axes -> the my.users entry features/users consumes. Only the
        axes that already have machinery are allowed through; everything else
        is refused here rather than approximated.

        `uid` is NOT passed on yet. Both hosts' accounts were created without a
        pinned uid, and pinning one now changes users-groups.json -- a system
        change this refactor is not allowed to make. The registry uids match
        the live ones (r0k0r 1000 on both, benjamin 1001 on victus-15, checked
        2026-10-17), so turning it on later is a no-op on disk.
        TODO: pass uid through, accepting that one cheap rebuild.
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
              groups = h.groups.${n} or u.groups or null;
            in
            if u.type == "handover" then
              notYet where "the handover type"
            else if e.home != "persistent" then
              notYet where "home = \"${e.home}\""
            else if e.nix == "overlay" || e.nix == "none" then
              notYet where "nix = \"${e.nix}\""
            else if sessionKind e.session == "kiosk" then
              notYet where "a kiosk session"
            else if groups != null && (elem "wheel" groups != elem "sudo" e.grants) then
              throw ''
                registry: ${where}: groups ${if elem "wheel" groups then "include" else "omit"} wheel but grants
                ${if elem "sudo" e.grants then "include" else "omit"} "sudo". wheel IS sudo here; make them agree.''
            else
              {
                primary = n == h.primary;
                home = e.session == "home-manager";
              }
              // lib.optionalAttrs (u ? description) { inherit (u) description; }
              // lib.optionalAttrs (u ? passwordSecret) { inherit (u) passwordSecret; }
              // lib.optionalAttrs (u ? stateVersion) { inherit (u) stateVersion; }
              // lib.optionalAttrs (u ? shell) { shell = pkgs.${u.shell}; }
              // lib.optionalAttrs (groups != null) { extraGroups = groups; }
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
        materialize
        ;
      check = globalOk;
    };
}
