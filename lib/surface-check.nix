/*
  Surface compatibility: can a home built from ITS package set safely load
  the system's in-process code? docs/multiuser-design.md, "Surface
  compatibility".

  A library ends up in one process twice-built when a home's program (from
  the user's set) loads system code (from the system's set) that links the
  same library: the loader reuses the copy already loaded -- the user's --
  for the system code compiled against the other one. Same version, same
  source and same patches: only flags differ, and that is fine. Same version
  but a different source or patch list: the two builds may not share an ABI.

  WHAT IS COMPARED. Package objects, walked the way the classifier walks
  them (buildInputs + propagatedBuildInputs, tuning/runtime-cache/lookup.nix):
    system side  the surface roots below, in the system's set
    user side    the home's home.packages, in the home's set
  keyed by pname, identity = version + source + patches. Patches and
  sources that are files in the nixpkgs tree are compared by CONTENT (the
  fork and upstream are different trees with mostly identical files), fetched
  ones by their fixed output path.

  SURFACE ROOTS, from the system config, as objects (lib/epoch.nix computes
  the same surface as derivation paths, which cannot be walked without
  building):
    graphics   hardware.graphics.package + extraPackages
    nss        system.nssModules.list
    locale     i18n.glibcLocales
    pam        the packages providing each enabled PAM rule's module, found
               by matching modulePath's derivation against systemd,
               security.pam.package and environment.systemPackages
    profile    environment.systemPackages: the system profile's plugin
               directories (Qt, GTK, GIO, GStreamer) are on every user's
               search paths, so anything installed there can be loaded
  A PAM module whose package is none of those is reported as unchecked.

  A home with its OWN graphics driver (my.graphics.driver, features/session/
  gl-namespace) is checked with `skip = [ "graphics" ]`, and homeLib runs a
  second check the other way round -- its tree against the system profile,
  reported as group "driver" -- because system programs in its sessions load
  that tree.
*/
{ lib }:

let
  isPath = builtins.isPath;
  /*
    One identity per input, stable across the two trees:
      a file in the nixpkgs tree    its content (fork and upstream are
                                    different trees with mostly equal files)
      a fetched (fixed-output) drv  its output path, which is its hash
      a GENERATED drv               its name only -- e.g. qtdeclarative's
                                    dont-cache-nix-store-paths.patch is made
                                    per package set with store paths
                                    substituted in, so its path always
                                    differs and says nothing about the ABI
  */
  inputId =
    x:
    if isPath x then
      # The name for the reader, the content hash for the comparison.
      "${baseNameOf x}#${
        builtins.substring 0 12 (
          if builtins.readFileType x == "regular" then builtins.hashFile "sha256" x else builtins.hashString "sha256" (toString (builtins.path { path = x; }))
        )
      }"
    else if lib.isDerivation x then
      (if x ? outputHash then toString x else "generated:${x.name or "?"}")
    else
      toString x;

  # Keyed by NAME only: two builds of one library in a process is the
  # problem whether or not their versions agree, and a version difference is
  # the worse case (the fork and nixpkgs-upstream can sit on different
  # revisions). Version is part of the identity below.
  keyOf = p: p.pname or (lib.getName p);
  idOf =
    p:
    let
      r = builtins.tryEval {
        version = p.version or "";
        src = if p ? src && p.src != null then inputId p.src else "";
        patches = map inputId (lib.toList (p.patches or [ ]));
      };
    in
    # Context discarded: an identity is compared, never built.
    if r.success then builtins.unsafeDiscardStringContext (builtins.toJSON r.value) else "unevaluable";

  isPkg = p: lib.isDerivation p && (p ? pname || p ? name);
  # A derivation without a source (a wrapper, an env, a stub) has no build
  # of its own to disagree about.
  hasSource = p: (builtins.tryEval (p ? src && p.src != null)).value or false;
  edges =
    p:
    let
      r = builtins.tryEval ((p.buildInputs or [ ]) ++ (p.propagatedBuildInputs or [ ]));
    in
    lib.filter isPkg (lib.flatten (if r.success then r.value else [ ]));

  # key -> { id, via } over the closure of `roots`; via = the root (by name)
  # through which the walk first reached it.
  walk =
    roots:
    let
      closure = builtins.genericClosure {
        startSet = map (p: {
          key = keyOf p;
          inherit p;
          via = p.name or (keyOf p);
        }) (lib.filter isPkg roots);
        operator = { p, via, ... }: map (q: { key = keyOf q; p = q; inherit via; }) (edges p);
      };
    in
    lib.listToAttrs (
      map (e: {
        name = e.key;
        value = {
          id = idOf e.p;
          inherit (e) via;
        };
      }) (lib.filter (e: hasSource e.p) closure)
    );

  contextDrvs = s: lib.attrNames (builtins.getContext (toString s));
in
{
  /*
    check { osConfig, homePackages } -> { conflicts, unchecked, roots }
      conflicts  [ { library, group, root, system, user } ]: same
                 pname, different version/source/patches; root = the system
                 item (of that surface group) that reaches it
      unchecked  PAM module paths whose package could not be identified
  */
  check =
    {
      osConfig,
      homePackages,
      # The same home on the system's own set: mixing that already happens
      # there (the system set itself holds two builds of a few libraries --
      # host-built and upstream-substituted) is not the user's choice and is
      # not reported.
      baselinePackages ? [ ],
      # Surface groups to leave out. A home with its own graphics driver
      # (my.graphics.driver, features/session/gl-namespace) skips "graphics":
      # the system's tree is not loaded into its processes.
      skip ? [ ],
    }:
    let
      c = osConfig;
      pool = [ c.systemd.package c.security.pam.package ] ++ c.environment.systemPackages;
      byDrv = lib.listToAttrs (
        map (p: { name = builtins.unsafeDiscardStringContext p.drvPath; value = p; }) (lib.filter lib.isDerivation pool)
      );
      pamPaths = lib.unique (
        lib.concatLists (
          lib.mapAttrsToList (
            _: s:
            lib.concatMap (
              type:
              lib.concatMap (
                # include/substack name another stack ("login"), not a module.
                r: lib.optional (r.enable && !(lib.elem r.control [ "include" "substack" ])) r.modulePath
              ) (lib.attrValues (s.rules.${type} or { }))
            ) [ "account" "auth" "password" "session" ]
          ) c.security.pam.services
        )
      );
      pamResolved = map (m: {
        path = m;
        pkgs = lib.filter (x: x != null) (map (d: byDrv.${d} or null) (contextDrvs m));
      }) pamPaths;

      groups = removeAttrs {
        graphics = lib.optionals (c.hardware.graphics.enable or false) (
          lib.optional (c.hardware.graphics.package or null != null) c.hardware.graphics.package
          ++ (c.hardware.graphics.extraPackages or [ ])
        );
        nss = c.system.nssModules.list;
        locale = lib.optional (c.i18n.glibcLocales != null) c.i18n.glibcLocales;
        pam = lib.concatMap (r: r.pkgs) pamResolved;
        profile = c.environment.systemPackages;
      } skip;

      user = walk homePackages;
      base = walk baselinePackages;
      perGroup = lib.mapAttrs (_: walk) groups;
      conflicts = lib.concatLists (
        lib.mapAttrsToList (
          group: sys:
          lib.concatMap (
            k:
            lib.optional (
              user ? ${k}
              && user.${k}.id != sys.${k}.id
              && !(base ? ${k} && base.${k}.id == user.${k}.id)
            ) {
              library = k;
              inherit group;
              root = sys.${k}.via;
              system = sys.${k}.id;
              user = user.${k}.id;
            }
          ) (lib.attrNames sys)
        ) perGroup
      );
    in
    {
      inherit conflicts;
      unchecked = map (r: r.path) (lib.filter (r: r.pkgs == [ ]) pamResolved);
      roots = lib.mapAttrs (_: builtins.length) groups;
    };

  /*
    The failure text for a home whose set conflicts. Long on purpose: the
    person reading it chose a tuning, not a theory of dynamic loading.
  */
  explain =
    {
      who,
      levers,
      hostLevers,
      result,
      # Extra lines for WHAT YOU CAN DO.
      hints ? [ ],
    }:
    let
      fmt = lv: "{ march = ${if lv.march == null then "none" else lv.march}; lto = ${lib.boolToString lv.lto}; o3 = ${lib.boolToString lv.o3}; }";
      groupText = {
        graphics = "the graphics driver every GL/Vulkan program loads (/run/opengl-driver)";
        nss = "NSS modules glibc loads for user and host lookups";
        locale = "the glibc locale archive";
        pam = "PAM modules, which your screen locker loads to check your password";
        profile = "plugins in the system profile (Qt, GTK, GIO, GStreamer, IM modules), which are on your programs' plugin search paths";
        # The other direction: homeLib relabels the check of a home's own
        # driver tree against the system profile.
        driver = "YOUR graphics driver (my.graphics.driver), the other way round: the system's programs in your sessions (the compositor, the system terminal, anything in the system profile) load it from /run/opengl-driver";
      };
      byLib = lib.groupBy (c: c.library) result.conflicts;
      describe =
        l: cs:
        let
          c = lib.head cs;
          s = builtins.fromJSON c.system;
          u = builtins.fromJSON c.user;
          onlySys = lib.subtractLists u.patches s.patches;
          onlyUser = lib.subtractLists s.patches u.patches;
        in
        "  ${l}\n"
        + lib.concatMapStrings (x: "      reached through ${x.group}: ${x.root}\n") cs
        + lib.optionalString (s.version != u.version) "      different VERSION: system ${s.version}, yours ${u.version}\n"
        + lib.optionalString (s.src != u.src) "      different source: system ${s.src}, yours ${u.src}\n"
        + lib.optionalString (onlySys != [ ]) "      ${toString (builtins.length onlySys)} patch(es) only in the system's build: ${lib.concatStringsSep ", " onlySys}\n"
        + lib.optionalString (onlyUser != [ ]) "      ${toString (builtins.length onlyUser)} patch(es) only in yours: ${lib.concatStringsSep ", " onlyUser}\n";
      groups = lib.unique (map (c: c.group) result.conflicts);
      marchSplit = levers.march != hostLevers.march;
    in
    ''
      ${who}: this home's package set cannot safely load the system's in-process code.

      my.tuning here gives ${fmt levers}; the system's own set is ${fmt hostLevers}.

      WHAT HAPPENS. The system loads some of ITS builds into YOUR processes:
      ${lib.concatMapStringsSep "\n" (g: "  - ${groupText.${g}}") groups}
      Your programs come from your package set. When a system plugin links a library
      your program has already loaded, the dynamic loader reuses YOUR copy for it. That
      is fine when both builds are the same source with the same patches -- compiler
      flags (march, -O3, LTO) do not change what the code expects. These libraries
      differ in source or patches between the two sets ("reached through" follows the
      system item's declared inputs, the way the tuning classifier walks them):

      ${lib.concatStrings (lib.mapAttrsToList describe byLib)}
      WHY IT MATTERS. The system's code was compiled against the other build. If a
      patch changed an interface -- a struct layout, a config.h define, an exported
      symbol -- the result is a crash or silent corruption, typically the first time
      that code runs: a lock screen that crashes when you unlock, a program that aborts
      at startup, a plugin that misbehaves. This cannot be decided from the patches'
      names, so the home is refused rather than built.

      WHAT YOU CAN DO.
      ${
        if marchSplit then
          ''
            - Keep march the same as the system: my.tuning.march = "system"; (or true).
              The two sets differ here because ${
                if hostLevers.march != null then
                  "the system's is a march (IntraISACross) build -- a cross build, which applies cross-only build patches to these libraries -- and yours is not"
                else
                  "yours is a march (IntraISACross) build and the system's is not"
              }.
              lto and o3 only change flags and can stay whatever you like.''
        else
          "- Set the lever that differs from the system's back to \"system\"."
      }
      - Or leave the libraries above out of your home's closure, if a program you
        added is what pulls them in.${lib.concatMapStrings (h: "\n- ${h}") hints}
      There is no override: a library built twice with different patches in one
      process is the one combination this check exists to stop. If you think these
      patches cannot change an interface, take it to the admin.
      '';
}
