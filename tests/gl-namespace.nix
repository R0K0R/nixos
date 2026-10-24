/*
  features/session/gl-namespace on synthetic copies of victus-15 (two
  standalone accounts; r0k0r mapped, benjamin not; enable32Bit, so the -32
  tree too) and galaxybook4-pro360 (greetd, and Hyprland's cap_sys_nice
  wrapper, which the privileged-GL assertion must refuse).

  Evaluation only -- nothing mounts, logs in or builds. Pinned down: the
  namespace.conf line names exactly the mapped users; pam_exec select runs
  before pam_namespace in every session stack, greetd through `include
  login`; /run/opengl-driver goes through the view while the system's tree
  is the SAME derivation (and the epoch the same) as without the feature;
  instance seeds, GC-root dir and path units for mapped users only; the home
  half links its tree into the generation, and only when on; the fallback
  session routes cage through gl-system-driver; the surface check can skip
  groups. `refused.*` must fail. Run: tests/gl-namespace-eval.sh, and
  tests/gl-namespace-select.sh for the select script itself.
*/
{ lib, mkHostWith, mkHomeLib, setuidGlChecks }:

let
  victus = "victus-15";
  gb4 = "galaxybook4-pro360";

  hostWith =
    host: extra:
    mkHostWith {
      hostName = host;
      extraModules = [ extra ];
    };

  on = hostWith victus {
    my.gl-namespace.enable = true;
    my.gl-namespace.users = [ "r0k0r" ];
  };
  c = on.config;
  off = mkHostWith { hostName = victus; };
  defaults = hostWith victus { my.gl-namespace.enable = true; };

  # galaxybook: greetd, and the Hyprland wrapper disabled so it is active.
  gbOn = hostWith gb4 {
    my.gl-namespace.enable = true;
    security.wrappers.Hyprland.enable = lib.mkForce false;
  };

  expect =
    what: cond: seen:
    if cond then seen else throw "gl-namespace: ${what}: got ${seen}";
  mustFail =
    what: v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then throw "gl-namespace: ${what} was accepted, should have been refused" else "refused";
  # Under CA an output path is a placeholder: name a derivation by its context.
  ctxHas = suffix: str: lib.any (lib.hasSuffix suffix) (lib.attrNames (builtins.getContext str));
  failing = cfg: map (a: a.message) (lib.filter (a: !a.assertion) cfg.config.assertions);

  pamText = cfg: svc: cfg.config.security.pam.services.${svc}.text;
  nsConf = c.environment.etc."security/namespace.conf".text;
  tf = c.systemd.tmpfiles.settings;
  tfOff = off.config.systemd.tmpfiles.settings.graphics-driver;
  selectLine = lib.findFirst (lib.hasInfix "gl-driver-select") "" (lib.splitString "\n" (pamText on "login"));

  hl = mkHomeLib victus on;
  homeOn = hl.mkHome {
    username = "r0k0r";
    modules = [ { my.graphics.driver.enable = true; } ];
  };
  homeOff = hl.mkHome { username = "r0k0r"; };

  sc = import ../lib/surface-check.nix { inherit lib; };
in
{
  toplevel = c.system.build.toplevel.drvPath;

  # -- who -------------------------------------------------------------------
  namespaceConf = expect "view polyinstantiated for r0k0r only" (
    lib.hasInfix "/run/gl-driver/view /run/gl-driver/inst/ user:noinit ~r0k0r\n" nsConf
    && !(lib.hasInfix "benjamin" nsConf)
  ) nsConf;
  defaultUsers = expect "default: every standalone account" (
    defaults.config.my.gl-namespace.users == [ "benjamin" "r0k0r" ]
  ) (toString defaults.config.my.gl-namespace.users);
  realHostUntouched = expect "real victus-15: no namespace.conf, no pam_exec select, plain link" (
    !(off.config.environment.etc ? "security/namespace.conf")
    && !(lib.hasInfix "gl-driver-select" (pamText off "login"))
    && !(off.config.systemd.tmpfiles.settings ? gl-namespace)
    && ctxHas "-graphics-drivers.drv" tfOff."/run/opengl-driver"."L+".argument
  ) tfOff."/run/opengl-driver"."L+".argument;

  # -- sessions --------------------------------------------------------------
  pam = expect "select then namespace in login, su, systemd-user, sshd, sudo" (
    lib.all (
      s:
      let
        t = pamText on s;
        parts = lib.splitString "pam_namespace.so" t;
      in
      lib.length parts == 2 && lib.hasInfix "gl-driver-select" (lib.head parts)
    ) [ "login" "su" "systemd-user" "sshd" "sudo" ]
  ) (toString c.my.gl-namespace.pamServices);
  pamSelectArgs = expect "pam_exec optional, open_session only, before pam_systemd" (
    lib.hasPrefix "session optional " selectLine
    && lib.hasInfix "type=open_session" selectLine
    && lib.hasInfix "pam_namespace.so" (lib.head (lib.splitString "pam_systemd.so" (pamText on "login")))
  ) selectLine;
  selectScriptEnv = expect "select script: fixed root, mapped users, 32-bit on" (
    let
      t = c.my.gl-namespace.internal.select.text;
    in
    lib.hasInfix "export GL_NS_ROOT=/run/gl-driver\n" t
    && lib.hasInfix "export GL_NS_USERS=r0k0r\n" t
    && lib.hasInfix "export GL_NS_32=1\n" t
  ) (toString c.my.gl-namespace.internal.select);
  greetdViaLogin = expect "greetd: not listed itself, its session includes login, pam_namespace once" (
    let
      t = pamText gbOn "greetd";
    in
    !(lib.elem "greetd" gbOn.config.my.gl-namespace.pamServices)
    && lib.hasInfix "session include login" t
    && !(lib.hasInfix "pam_namespace" t)
    && lib.hasInfix "pam_namespace.so" (pamText gbOn "login")
  ) (pamText gbOn "greetd");

  # -- the tree -----------------------------------------------------------------
  viewLinks = expect "/run/opengl-driver(-32) through the view" (
    tf.graphics-driver."/run/opengl-driver"."L+".argument == "/run/gl-driver/view/tree"
    && tf.graphics-driver."/run/opengl-driver-32"."L+".argument == "/run/gl-driver/view/tree-32"
    && tf.gl-namespace."/run/gl-driver/view/tree"."L+".argument == "/run/gl-driver/system"
  ) (builtins.toJSON tf.graphics-driver."/run/opengl-driver");
  sameSystemTree = expect "the system's tree is the same derivation as without the feature" (
    tf.graphics-driver."/run/gl-driver/system"."L+".argument == tfOff."/run/opengl-driver"."L+".argument
    && tf.graphics-driver."/run/gl-driver/system-32"."L+".argument == tfOff."/run/opengl-driver-32"."L+".argument
  ) tf.graphics-driver."/run/gl-driver/system"."L+".argument;
  sameEpoch = expect "epoch unchanged by the feature" (
    c.system.build.epoch == off.config.system.build.epoch && c.system.build.epoch != "empty"
  ) c.system.build.epoch;
  instances = expect "instance parent 0000; seeds (L, not L+) for r0k0r only; gcroot dir" (
    let
      g = tf.gl-namespace;
    in
    g."/run/gl-driver/inst".d.mode == "0000"
    && g."/run/gl-driver/inst/r0k0r/tree".L.argument == "/run/gl-driver/system"
    && g."/run/gl-driver/inst/r0k0r/tree-32".L.argument == "/run/gl-driver/system-32"
    && !(g ? "/run/gl-driver/inst/r0k0r/tree"."L+")
    && !(g ? "/run/gl-driver/inst/benjamin")
    && g ? "/nix/var/nix/gcroots/gl-driver"
  ) (toString (lib.attrNames tf.gl-namespace));
  pathUnits = expect "profile watch for r0k0r only, template service" (
    c.systemd.paths ? gl-driver-select-r0k0r
    && !(c.systemd.paths ? gl-driver-select-benjamin)
    && lib.elem "/home/r0k0r/.local/state/nix/profiles/home-manager" c.systemd.paths.gl-driver-select-r0k0r.pathConfig.PathChanged
    && c.systemd.paths.gl-driver-select-r0k0r.pathConfig.Unit == "gl-driver-select@r0k0r.service"
    && c.systemd.services ? "gl-driver-select@"
  ) (toString (lib.attrNames c.systemd.paths));

  # -- homes -------------------------------------------------------------------
  homeLinksTree = expect "my.graphics.driver: generation links the tree" (
    let
      t = homeOn.config.home.extraBuilderCommands;
    in
    ctxHas "-graphics-drivers.drv" t
    && lib.hasInfix "$out/graphics-driver\n" t
    && !(lib.hasInfix "graphics-driver-32" t)
    && lib.hasInfix "graphics-drivers" homeOn.config.my.graphics.driver.tree.name
  ) homeOn.config.home.extraBuilderCommands;
  homeDefaultPackages = expect "default packages: the system's, by pname, from the home's set" (
    map (p: p.pname or (lib.getName p)) homeOn.config.my.graphics.driver.packages == [ "mesa" "nvidia-vaapi-driver" ]
  ) (toString (map (p: p.pname or (lib.getName p)) homeOn.config.my.graphics.driver.packages));
  homeWarnsNvidia = expect "nvidia-x11 is not a top-level attribute: warned" (
    lib.any (lib.hasInfix "nvidia-x11") homeOn.config.warnings
  ) (toString homeOn.config.warnings);
  homeOffNoLink = expect "without it: no link, same activation package as before" (
    !(lib.hasInfix "graphics-driver" homeOff.config.home.extraBuilderCommands)
  ) "no link";
  # A set that is not the host's (lto off): the surface check runs with the
  # driver half-turned (graphics skipped, the tree checked against the
  # system profile as group "driver") and the home still evaluates.
  ownDriverOtherSet = expect "own driver on a non-host set evaluates" (
    let
      h = hl.mkHome {
        username = "r0k0r";
        modules = [
          {
            my.tuning.lto = false;
            my.graphics.driver.enable = true;
          }
        ];
      };
    in
    lib.hasSuffix ".drv" h.activationPackage.drvPath
    && h.config.my.graphics.driver.tree.drvPath != homeOn.config.my.graphics.driver.tree.drvPath
  ) "evaluates, own tree";
  facts = expect "facts.graphics" (
    hl.facts.graphics.perUserDriver == [ "r0k0r" ] && (mkHomeLib victus off).facts.graphics.perUserDriver == [ ]
  ) (builtins.toJSON hl.facts.graphics);

  # -- fallback session, surface check, setuid check -----------------------------
  fallbackUsesSystemDriver = expect "fallback-session runs cage through gl-system-driver" (
    let
      fb = hostWith victus {
        my.gl-namespace.enable = true;
        my.epoch.enable = true;
        my.fallback-session.enable = true;
      };
      p = lib.findFirst (p: (p.name or "") == "fallback-session") null fb.config.environment.systemPackages;
    in
    p != null && lib.hasInfix "cage() { gl-system-driver cage" (p.text or "")
  ) "ok";
  surfaceSkip = expect "surface check: skip drops groups" (
    let
      r = sc.check {
        osConfig = c;
        homePackages = [ ];
        skip = [ "graphics" "nss" "locale" "pam" ];
      };
    in
    lib.attrNames r.roots == [ "profile" ]
  ) "ok";
  setuidCheck = expect "setuidGlChecks: a derivation over the privileged wrappers, not in checks while off" (
    let
      d = setuidGlChecks.${victus};
    in
    lib.hasInfix "setuid-no-gl-victus-15" d.drvPath
    && lib.elem "sudo" (lib.attrNames d.wrappers)
    && d.exportReferencesGraph ? "closure-unix_chkpwd"
  ) setuidGlChecks.${victus}.drvPath;

  refused = {
    hyprlandCap = expect "galaxybook's cap_sys_nice Hyprland wrapper loads GL" (
      lib.any (m: lib.hasInfix "security.wrappers.Hyprland" m && lib.hasInfix "loads GL" m) (
        failing (hostWith gb4 { my.gl-namespace.enable = true; })
      )
    ) "refused";
    hyprlandAllowed = expect "allowPrivilegedGL.Hyprland lifts it" (
      !(lib.any (lib.hasInfix "loads GL") (
        failing (hostWith gb4 {
          my.gl-namespace.enable = true;
          my.gl-namespace.allowPrivilegedGL.Hyprland = "test";
        })
      ))
    ) "allowed";
    unknownUser = expect "a user who is not an account" (
      lib.any (lib.hasInfix "nosuchuser is not an account") (
        failing (hostWith victus {
          my.gl-namespace.enable = true;
          my.gl-namespace.users = [ "nosuchuser" ];
        })
      )
    ) "refused";
    unmappedHome = mustFail "my.graphics.driver for an unmapped user" (
      (mkHomeLib victus on).mkHome {
        username = "benjamin";
        modules = [ { my.graphics.driver.enable = true; } ];
      }
    ).activationPackage.drvPath;
    noFeatureHome = mustFail "my.graphics.driver on a host without gl-namespace" (
      (mkHomeLib victus off).mkHome {
        username = "r0k0r";
        modules = [ { my.graphics.driver.enable = true; } ];
      }
    ).activationPackage.drvPath;
  };
}
