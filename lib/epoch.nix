/*
  A host's EPOCH: one hash over the derivations the system pushes INTO user
  processes, so that "can this home generation run on this system?" becomes a
  string comparison.

  WHAT COUNTS (the "surface"). A home-manager generation is built against one
  system revision and then runs against whatever system is booted. Almost all
  of the system is reached by exec -- a user program calling /run/wrappers or
  /run/current-system/sw/bin gets that program's own closure, glibc included,
  and nothing mixes. What DOES mix is code and data the system loads into a
  process the user built:

    env        environment.variables / environment.sessionVariables /
               systemd.globalEnvironment values that name store paths
               (GIO/GTK/QT module paths, an IM module cache, LOCALE_ARCHIVE
               when it points into the store). Read from STRING CONTEXT, not by
               pattern-matching "/nix/store": the context is exactly the set of
               derivations Nix itself knows the string depends on, so a
               variable cannot slip past by being spelled oddly.
    graphics   /run/opengl-driver(-32) -- the buildEnv graphics.nix links
               there (/run/gl-driver/system(-32) under gl-namespace),
               taken from its tmpfiles argument so it is the same
               derivation the system installs, not a reconstruction of it.
               libGL/Vulkan ICDs are dlopen'ed from here by every GL program,
               which is why an NVIDIA driver bump is the classic epoch.
    pam        modulePath of every enabled rule of every security.pam service.
               A user's screen locker (hyprlock, swaylock) loads these
               in-process. Only modulePath, not args: a pam_exec helper is
               exec'ed, not loaded.
    nss        system.nssModules -- loaded in-process by glibc when nscd is
               not answering.
    locale     i18n.glibcLocales: the archive every glibc program maps.
    extra      my.epoch.extraSurface, for what the admin knows about and the
               list above cannot see.

  DRV PATHS, NOT OUT PATHS. Under content addressing (tuning/ca.nix) an
  output path is unknown until it is built, so hashing outPaths would either
  fail to evaluate or force a build. A drvPath is fixed at evaluation. The
  price: a change that rebuilds to identical bytes still bumps the epoch. That
  errs on the safe side -- a spurious epoch costs a home rebuild, a missed one
  costs a broken session.

  Store paths that are plain sources (no derivation) appear in a context as
  themselves and are hashed as they are; they are content-addressed already.

  Pure function of the evaluated config: no option is declared here, so the
  same function serves the epoch feature, homeLib and any external checker.
*/
{ lib }:

config:

let
  /*
    Context of a value, as a list of store paths: a .drv for anything built
    (the context key of an output reference IS its drvPath), the path itself
    for a source. Lists are flattened; non-strings contribute nothing.
  */
  contextOf =
    v:
    if builtins.isList v then
      lib.concatMap contextOf v
    else if builtins.isString v || builtins.isPath v || lib.isDerivation v then
      lib.attrNames (builtins.getContext (toString v))
    else
      [ ];

  /*
    One entry per contributing store path, with WHY it is there, so the report
    answers "what do I shrink" without a second tool.
  */
  entriesFrom =
    category: via: v:
    map (p: {
      inherit category via;
      path = builtins.unsafeDiscardStringContext p;
      name = lib.removeSuffix ".drv" (
        builtins.substring 33 (-1) (builtins.unsafeDiscardStringContext (baseNameOf p))
      );
    }) (lib.unique (contextOf v));

  envEntries =
    lib.concatLists (
      lib.mapAttrsToList (n: v: entriesFrom "env" "environment.variables.${n}" v) config.environment.variables
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        n: v: entriesFrom "env" "environment.sessionVariables.${n}" v
      ) config.environment.sessionVariables
    )
    ++ lib.concatLists (
      lib.mapAttrsToList (
        n: v: entriesFrom "env" "systemd.globalEnvironment.${n}" v
      ) config.systemd.globalEnvironment
    );

  # features/session/gl-namespace moves the system's tree one link down
  # (/run/opengl-driver -> view -> /run/gl-driver/system); the tree, and so
  # the epoch, is the same.
  graphicsEntries =
    let
      g = config.systemd.tmpfiles.settings.graphics-driver or { };
      arg = p: g.${p}."L+".argument or null;
    in
    lib.optionals (config.hardware.graphics.enable or false) (
      lib.concatMap (
        p: lib.optionals (arg p != null) (entriesFrom "graphics" p (arg p))
      ) [ "/run/opengl-driver" "/run/opengl-driver-32" "/run/gl-driver/system" "/run/gl-driver/system-32" ]
    );

  pamEntries = lib.concatLists (
    lib.mapAttrsToList (
      svc: s:
      lib.concatMap (
        type:
        lib.concatLists (
          lib.mapAttrsToList (
            rn: r:
            lib.optionals r.enable (entriesFrom "pam" "security.pam.services.${svc}.rules.${type}.${rn}" r.modulePath)
          ) (s.rules.${type} or { })
        )
      ) [ "account" "auth" "password" "session" ]
    ) config.security.pam.services
  );

  nssEntries = entriesFrom "nss" "system.nssModules" config.system.nssModules.list;

  localeEntries = lib.optionals (config.i18n.glibcLocales != null) (
    entriesFrom "locale" "i18n.glibcLocales" config.i18n.glibcLocales
  );

  extraEntries = entriesFrom "extra" "my.epoch.extraSurface" (config.my.epoch.extraSurface or [ ]);

  all = envEntries ++ graphicsEntries ++ pamEntries ++ nssEntries ++ localeEntries ++ extraEntries;

  /*
    my.epoch.ignoreSurface: derivation NAMES reached by the routes above that
    are known not to be loaded into user processes. Matched by name, not by
    path, so the exclusion survives the derivation changing -- which is the
    whole point. Still listed in the report, under "ignored".
  */
  ignored = config.my.epoch.ignoreSurface or [ ];
  isIgnored = e: builtins.elem e.name ignored;
  entries = lib.filter (e: !isIgnored e) all;
  ignoredEntries = map (e: e // { category = "ignored"; }) (lib.filter isIgnored all);

  # The hashed set: each store path once, however many routes lead to it.
  paths = lib.sort lib.lessThan (lib.unique (map (e: e.path) entries));

  /*
    "empty" for an empty surface rather than the hash of "": a host that has
    reached zero in-process system code has nothing to be incompatible WITH,
    and saying so is more useful than an opaque constant.
  */
  epoch =
    if paths == [ ] then
      "empty"
    else
      builtins.substring 0 20 (builtins.hashString "sha256" (lib.concatStringsSep "\n" paths));
in
{
  inherit epoch paths;

  /*
    category -> store path -> { name, via = [ the options that reach it ] }.
    `nix eval .#nixosConfigurations.<host>.config.my.epoch.surfaceReport --json`
  */
  report = lib.mapAttrs (
    _: es:
    lib.mapAttrs (_: same: {
      name = (lib.head same).name;
      via = lib.unique (map (e: e.via) same);
    }) (lib.groupBy (e: e.path) es)
  ) (lib.groupBy (e: e.category) (entries ++ ignoredEntries));
}
