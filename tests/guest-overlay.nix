/*
  features/nix/guest-overlay on a synthetic copy of victus-15: my.btrfs-layout
  and my.guest-overlay on, and one registry user, `guest` (type untrusted,
  nix = "overlay", a standalone home-manager session), added through
  my.registry.extend with the host fact features.victus-15."guest-overlay".

  Evaluation only -- nothing here mounts, snapshots or logs in. What it pins
  down is the wiring: the namespace.conf lines, pam_namespace in every
  session stack and nowhere for other users, the guest's nix.conf, the
  units and their ordering, the shared daemon refusing the guest, facts.
  `refused.*` must fail to evaluate. Run: tests/guest-overlay-eval.sh.
*/
{ lib, mkHostWith, mkHomeLib }:

let
  host = "victus-15";

  extendWith =
    userExtra: hostFact: raw:
    raw
    // {
      users = raw.users // {
        guest = {
          uid = 1902;
          type = "untrusted";
          overrides = {
            nix = "overlay";
            session = "home-manager";
          };
          homeActivation = "standalone";
          # victus-15 has mutableUsers = false: every account needs one. Any
          # secret will do for an evaluation.
          passwordSecret = ../age/hashed-password-benjamin.age;
        }
        // userExtra;
      };
      hosts = raw.hosts // {
        hosts = raw.hosts.hosts // {
          ${host} = raw.hosts.hosts.${host} // {
            users = raw.hosts.hosts.${host}.users ++ [ "guest" ];
          };
        };
        features = raw.hosts.features // {
          ${host} = raw.hosts.features.${host} // {
            "guest-overlay" = hostFact;
          };
        };
      };
    };

  hostWith =
    { userExtra ? { }, hostFact ? true, layout ? true, overlay ? true, wrappers ? "hidden" }:
    mkHostWith {
      hostName = host;
      extraModules = [
        {
          my.registry.extend = extendWith userExtra hostFact;
          my.btrfs-layout.enable = lib.mkForce layout;
          my.guest-overlay.enable = overlay;
          my.guest-overlay.wrappers = wrappers;
        }
      ];
    };

  on = hostWith { };
  c = on.config;
  off = mkHostWith { hostName = host; };

  expect =
    what: cond: seen:
    if cond then seen else throw "guest-overlay: ${what}: got ${seen}";
  mustFail =
    what: v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then throw "guest-overlay: ${what} was accepted, should have been refused" else "refused";
  # Failed assertions, as NixOS would report them at toplevel time.
  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);

  pamText = svc: c.security.pam.services.${svc}.text;
  nsConf = c.environment.etc."security/namespace.conf".text;
  tmpfiles = c.systemd.tmpfiles.rules;
  confRule = lib.findFirst (lib.hasInfix "/.etc/guest/nix.conf") (throw "no tmpfiles rule for the guest nix.conf") tmpfiles;
  nixConfPath = lib.last (lib.splitString " " confRule);
  facts = (mkHomeLib host on).facts;
in
{
  toplevel = c.system.build.toplevel.drvPath;

  # -- namespace -------------------------------------------------------------
  namespaceConf = expect "store, /etc/nix and hidden wrappers for guest only" (
    lib.hasInfix "/nix/store /var/lib/nix-guests/.merged/ user:noinit ~guest" nsConf
    && lib.hasInfix "/etc/nix /var/lib/nix-guests/.etc/ user:noinit ~guest" nsConf
    && lib.hasInfix "/run/wrappers /var/lib/nix-guests/.wrappers/ tmpfs:noinit:mntopts=nosuid" nsConf
  ) nsConf;
  wrappersShared = expect "wrappers = shared drops the /run/wrappers line" (
    !(lib.hasInfix "/run/wrappers" (hostWith { wrappers = "shared"; }).config.environment.etc."security/namespace.conf".text)
  ) "no /run/wrappers line";

  pam = expect "pam_namespace in login, su, systemd-user, sshd, sudo" (
    lib.all (s: lib.hasInfix "pam_namespace.so" (pamText s)) [ "login" "su" "systemd-user" "sshd" "sudo" ]
  ) (toString c.my.guest-overlay.pamServices);
  pamOrder = expect "pam_namespace before pam_systemd in login" (
    let
      t = pamText "login";
      before = lib.head (lib.splitString "pam_systemd.so" t);
    in
    lib.hasInfix "pam_namespace.so" before
  ) "namespace first";
  realHostNoPam = expect "real victus-15 has no pam_namespace and no namespace.conf" (
    !(lib.hasInfix "pam_namespace" off.config.security.pam.services.login.text)
    && !(off.config.environment.etc ? "security/namespace.conf")
  ) "absent";

  # -- the guest's nix ------------------------------------------------------
  tmpfilesRules = expect "instance parents 0000, conf copied (C+), not linked" (
    lib.elem "d /var/lib/nix-guests/.merged 0000 root root -" tmpfiles
    && lib.elem "d /var/lib/nix-guests/.etc 0000 root root -" tmpfiles
    && lib.hasPrefix "C+ " confRule
  ) confRule;
  nixConf = expect "nix.conf opens the overlay store directly, max-jobs per host policy" (
    let
      t = c.my.guest-overlay.guestNixConf.guest;
    in
    lib.hasInfix "store = local-overlay://?lower-store=local%3Froot%3D/var/lib/nix-guests/guest/lower%26read-only%3Dtrue&upper-layer=/var/lib/nix-guests/guest/upper&state=/var/lib/nix-guests/guest/state" t
    && lib.hasInfix "local-overlay-store" t
    && lib.hasInfix "build-users-group =\n" t
    && lib.hasInfix "max-jobs = auto" t
  ) nixConfPath;

  # -- units -----------------------------------------------------------------
  units = expect "lower snapshot, overlay mount before logins, user@1902 drop-in" (
    let
      s = c.systemd.services;
      o = s.nix-guest-overlay-guest;
    in
    s ? nix-guest-lower
    && lib.elem "systemd-user-sessions.service" o.before
    && lib.elem "nix-guest-lower.service" o.after
    && !o.restartIfChanged
    && lib.elem "nix-guest-overlay-guest.service" s."user@1902".after
    && lib.hasInfix "restart nix-guest-overlay-guest.service" s."user@1902".serviceConfig.ExecStopPost
  ) "ok";
  activation = expect "activation asks for a new snapshot" (
    lib.hasInfix "restart --no-block nix-guest-lower.service" (let a = c.system.activationScripts.nix-guest-lower; in a.text or a)
  ) "ok";
  nixMount = expect "/nix from victus-15's subvolume" (lib.elem "subvol=nix" c.fileSystems."/nix".options) (
    toString c.fileSystems."/nix".options
  );

  # -- the shared daemon and the registry -------------------------------------
  allowedUsers = expect "the shared daemon refuses the guest" (
    !(lib.elem "guest" c.nix.settings.allowed-users) && lib.elem "r0k0r" c.nix.settings.allowed-users
  ) (toString c.nix.settings.allowed-users);
  notIntegrated = expect "standalone home: not in home-manager.users" (!(c.home-manager.users ? guest)) (
    toString (lib.attrNames c.home-manager.users)
  );
  guestFacts = expect "facts: own store, own builders, no daemon" (
    let
      g = facts.nix.users.guest;
    in
    g.store == "own" && g.ownBuilders && !g.daemon && !g.builds.remote
  ) (builtins.toJSON facts.nix.users.guest);

  refused = {
    # guest-overlay without /nix as a subvolume: _meta's requires.
    noLayout = expect "guest-overlay without btrfs-layout fails an assertion" (
      lib.any (lib.hasInfix "requires my.btrfs-layout.enable") (failing (hostWith { layout = false; }))
    ) "refused";
    # The registry fact and the switch must agree.
    factMismatch = expect "guest-overlay on, fact off" (
      lib.any (lib.hasInfix ''"guest-overlay" = false'') (failing (hostWith { hostFact = false; userExtra.overrides = { nix = "untrusted"; session = "home-manager"; }; }))
    ) "refused";
    # An overlay user on a host whose facts do not declare the feature.
    noFact = mustFail "nix = overlay without the host fact" (
      lib.attrNames (hostWith { hostFact = false; overlay = false; }).config.my.users
    );
    # The system cannot activate a home that lives in the guest's store.
    integratedHome = mustFail "overlay + integrated home" (
      lib.attrNames (hostWith { userExtra.homeActivation = "system"; }).config.my.users
    );
  };
}
