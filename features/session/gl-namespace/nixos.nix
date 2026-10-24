/*
  /run/opengl-driver per user, in the user's mount namespace
  (docs/multiuser-design.md, "Singletons and the epoch").

  WHY. Every GL/Vulkan/VA-API program dlopens its driver from
  /run/opengl-driver (libglvnd's vendor directory, the Vulkan loader's ICD
  directory, RUNPATH entries from addDriverRunpath). The driver is loaded INTO
  the program, so it must match the program's libc, LLVM and friends. With
  per-user tuning (home option my.tuning) a user's programs may come from a
  package set the system did not build, and the system's one driver tree is
  then the wrong one for them. A path that is baked into binaries cannot be
  chosen per process, but it can be chosen per MOUNT NAMESPACE: each mapped
  user's sessions see their own tree behind the same path.

  THE LAYOUT. One level of indirection turns "which tree" into a symlink that
  root can change without touching any mount:

    /run/opengl-driver      -> /run/gl-driver/view/tree      (all namespaces)
    /run/opengl-driver-32   -> /run/gl-driver/view/tree-32   (with enable32Bit)
    /run/gl-driver/system   -> the system's buildEnv          (L+, every activation)
    /run/gl-driver/view/    the polyinstantiated directory; outside a mapped
                            namespace it holds tree -> ../system
    /run/gl-driver/inst/    instance parent, 0000 root (pam_namespace insists)
    /run/gl-driver/inst/<user>/tree  -> the user's tree, or /run/gl-driver/system

  pam_namespace binds inst/<user> over view/ in that user's sessions. Its
  polydir must be a real directory: on the old symlink /run/opengl-driver it
  would follow the link and bind over the system tree's STORE PATH, which a
  system switch then leaves behind (the next switch repoints the symlink and
  the user silently gets the system's driver). The view directory is never
  replaced, so the bind survives switches, and a user who declares no driver
  follows the system's live because their link points at system, not at a
  store path.

  WHICH TREE. The home declares it (my.graphics.driver in the home half,
  home.nix): a buildEnv from the user's own package set, linked into the
  generation as $generation/graphics-driver -- so the home generation (a GC
  root through the user's profile) keeps it alive, and rolling the home back
  rolls the driver back. gl-driver-select (root) reads the user's CURRENT
  generation and repoints inst/<user>/tree:
    - at every session open (pam_exec, ahead of pam_namespace);
    - when the user's home-manager profile changes (a path unit), so new
      processes pick up a home switch without a re-login, the way they pick
      up a system switch;
  and keeps a root GC root for the selected tree (/nix/var/nix/gcroots/
  gl-driver/<user>), so deleting old generations and collecting garbage
  cannot remove a tree a running session still resolves.

  WHO. `users` (default: standalone home-manager accounts that are not
  overlay guests or kiosks) get the namespace; everyone else -- the greeter
  included, it runs as `greeter` -- keeps the plain system view. A mapped
  user without a declared driver is in a namespace whose tree is the
  system's: same files, same behaviour.

  WHERE. Every way a mapped user's processes start must polyinstantiate,
  exactly as for guest-overlay: `login` (greetd's session stack includes
  it, so greeter logins are covered there), `su`, `sudo`, `sshd`, and
  `systemd-user` -- the user manager. user@.service runs its own PAM session
  (PAMName=systemd-user) from PID 1, NOT inside the login session's namespace,
  so without it everything the user manager starts -- under uwsm the
  compositor and most of the desktop -- would see the system's tree. With it
  the manager gets a namespace of its own with the same bind of the same
  instance directory; the two namespaces stay in step because the choice
  lives in the instance's symlinks, not in the mounts.

  No init script, as in guest-overlay: nothing has to run as root inside the
  namespace, and the select step runs BEFORE pam_namespace in the root
  namespace. pam_namespace marks / slave (it detects the shared root), so the
  bind never propagates back.

  WHAT IT COSTS / TRUST.
    - A mapped user's tree is user-controlled code loaded into every process
      of their session, INCLUDING system programs they run there (the
      compositor, the system kitty). homeLib's surface check therefore checks
      the user's driver against the system profile's libraries too (lib/
      surface-check.nix, group "driver"), and the fallback session runs its
      cage/kitty through gl-system-driver.
    - A setuid/setcap program started in that namespace would load the user's
      driver with privileges. So no privileged wrapper may link GL:
      asserted at evaluation for what evaluation can see (the wrapper's own
      derivation and its declared inputs), and checked over the full runtime
      closures by a build-time check (setuidGlChecks.<host>, run on the
      builders, never part of the toplevel). Hyprland's cap_sys_nice wrapper
      fails it: disable that wrapper (Hyprland then runs without SCHED_RR) or
      list it in allowPrivilegedGL with the reason.
    - A root process started from a mapped session (sudo, pkexec) inherits
      the namespace and would load the user's driver if it used GL. sudo
      users can already run anything as root; pkexec with an admin's
      password typed into a user's session is already a compromised
      password. Accepted, not fixed.
    - graphics stays in the epoch: every unmapped user, the greeter and the
      fallback session still load the system's tree.

  Never run on a machine; evaluated by tests/gl-namespace.nix.
*/
{ config, lib, pkgs, ... }:

let
  cfg = config.my.gl-namespace;
  g = config.hardware.graphics;
  active = cfg.enable && g.enable && cfg.users != [ ];
  has32 = g.enable32Bit && !pkgs.stdenv.hostPlatform.isi686;

  root = "/run/gl-driver";
  gcroots = "/nix/var/nix/gcroots/gl-driver";

  # The same buildEnvs nixos/modules/hardware/graphics.nix links -- same
  # name, same paths, so the same derivations (the epoch sees no change).
  driversEnv = pkgs.buildEnv {
    name = "graphics-drivers";
    paths = [ g.package ] ++ g.extraPackages;
  };
  driversEnv32 = pkgs.buildEnv {
    name = "graphics-drivers-32bit";
    paths = [ g.package32 ] ++ g.extraPackages32;
  };

  selectTools = with pkgs; [
    coreutils
    getent
    util-linux # logger
  ];
  select = pkgs.writeShellScript "gl-driver-select" ''
    export PATH=${lib.makeBinPath selectTools}
    # Set unconditionally: a PAM environment must not redirect a root script.
    export GL_NS_ROOT=${root}
    export GL_NS_GCROOTS=${gcroots}
    export GL_NS_PERUSER=/nix/var/nix/profiles/per-user
    export GL_NS_STORE=/nix/store
    export GL_NS_OWNER=0
    export GL_NS_32=${if has32 then "1" else "0"}
    export GL_NS_USERS=${lib.escapeShellArg (toString cfg.users)}
    export GL_NS_HOME=
    ${builtins.readFile ./gl-driver-select.sh}
  '';

  gl-system-driver = pkgs.writeShellScriptBin "gl-system-driver" (builtins.readFile ./gl-system-driver.sh);

  namespaceConf = ''
    # Per-user graphics driver view (features/session/gl-namespace). The
    # instance parent is mode 0000, root's; no init script runs.
    ${root}/view ${root}/inst/ user:noinit ~${lib.concatStringsSep "," cfg.users}
  '';

  /*
    Privileged wrappers that load GL, as far as evaluation can tell: the
    wrapper's own derivation and everything its derivations declare as
    (propagated) build inputs, walked the way lib/surface-check.nix walks
    them. The source is a path string; its package object is found in the
    system profile (Hyprland's is there), otherwise only the derivation's
    name is seen. The build-time check (lib/setuid-gl-check.nix) sees the
    real closure.
  */
  glNames = [
    "mesa"
    "libglvnd"
    "libGL"
    "libgbm"
    "vulkan-loader"
    "libva"
    "libvdpau"
    "ocl-icd"
    "nvidia-x11"
    "egl-wayland"
  ];
  isGlName =
    n:
    lib.any (gn: n == gn || lib.hasPrefix "${gn}-" n) glNames;
  privileged = lib.filterAttrs (
    _: w: w.enable && (w.setuid || w.setgid || w.capabilities != "")
  ) config.security.wrappers;
  drvName = d: lib.removeSuffix ".drv" (builtins.substring 33 (-1) (baseNameOf d));
  pool = lib.listToAttrs (
    lib.concatMap (
      p:
      let
        r = builtins.tryEval (builtins.unsafeDiscardStringContext p.drvPath);
      in
      lib.optional (lib.isDerivation p && r.success) {
        name = r.value;
        value = p;
      }
    ) config.environment.systemPackages
  );
  edges =
    p:
    let
      r = builtins.tryEval ((p.buildInputs or [ ]) ++ (p.propagatedBuildInputs or [ ]));
    in
    lib.filter lib.isDerivation (lib.flatten (if r.success then r.value else [ ]));
  nameOf = p: p.pname or (lib.getName p);
  glReachedBy =
    w:
    let
      drvs = lib.attrNames (builtins.getContext (toString w.source));
      direct = lib.filter (d: isGlName (drvName d)) drvs;
      objs = lib.filter (x: x != null) (map (d: pool.${d} or null) drvs);
      closure = builtins.genericClosure {
        startSet = map (p: { key = nameOf p; inherit p; }) objs;
        operator = { p, ... }: map (q: { key = nameOf q; p = q; }) (edges p);
      };
    in
    lib.unique (map drvName direct ++ lib.filter isGlName (map (e: e.key) closure));
  glWrappers = lib.filterAttrs (n: hits: hits != [ ] && !(cfg.allowPrivilegedGL ? ${n})) (
    lib.mapAttrs (_: glReachedBy) privileged
  );
in
{
  options.my.gl-namespace = {
    enable = lib.mkEnableOption ''
      a per-user /run/opengl-driver: users in my.gl-namespace.users see the
      driver tree their home generation declares (home option
      my.graphics.driver), in their own mount namespace, and the system's
      tree when it declares none'';

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = lib.attrNames (
        lib.filterAttrs (
          _: u: u.home && u.homeActivation == "standalone" && u.nix != "overlay" && u.kiosk == null
        ) config.my.users
      );
      defaultText = lib.literalMD "standalone home-manager accounts that are not overlay guests or kiosks";
      description = ''
        Accounts whose sessions get the per-user driver view. Integrated homes
        are built from the system's set (nothing to map); overlay guests'
        trees live in their own store, which root's select step cannot see.
      '';
    };

    pamServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default =
        [
          "login"
          "su"
          "systemd-user"
        ]
        ++ lib.optional config.services.openssh.enable "sshd"
        ++ lib.optional config.security.sudo.enable "sudo";
      defaultText = lib.literalExpression ''[ "login" "su" "systemd-user" ] ++ sshd/sudo when enabled'';
      description = ''
        PAM services whose sessions select the user's tree and enter the
        namespace. greetd is not listed: its session stack is `include login`,
        so it gets login's rules (listing it would run pam_namespace twice).
        systemd-user is the user manager; without it user services see the
        system's tree.
      '';
    };

    allowPrivilegedGL = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        Hyprland = "cap_sys_nice only; accepted: a mapped user's driver may renice";
      };
      description = ''
        Privileged (setuid, setgid or setcap) wrappers allowed to load GL
        anyway, each with the reason. A mapped user's driver runs with that
        wrapper's privileges. Exempts the wrapper from both the evaluation
        assertion and the build-time check.
      '';
    };

    systemDriverEnv = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = gl-system-driver;
      defaultText = lib.literalMD "gl-system-driver";
      description = "`gl-system-driver CMD...`: runs CMD with the loaders pointed at the system's tree (the fallback session uses it).";
    };

    internal.select = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      default = select;
      description = "The gl-driver-select script (for tests: its text).";
    };

    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      default = active;
      description = "enable, graphics on and at least one mapped user (read by fallback-session, homes and the checks).";
    };
  };

  config = lib.mkMerge [
    {
      my.internal.features.gl-namespace.enabledBy = cfg.enable;
    }

    (lib.mkIf cfg.enable {
      assertions =
        [
          {
            assertion = g.enable;
            message = "my.gl-namespace needs hardware.graphics.enable (there is no driver tree to map).";
          }
        ]
        ++ map (n: {
          assertion = config.my.users ? ${n} && config.my.users.${n}.nix != "overlay";
          message =
            if config.my.users ? ${n} then
              "my.gl-namespace.users: ${n} is an overlay guest; their driver tree lives in their own store, which the root select step cannot see."
            else
              "my.gl-namespace.users: ${n} is not an account on ${config.networking.hostName}.";
        }) cfg.users
        ++ lib.mapAttrsToList (n: hits: {
          assertion = !active;
          message = ''
            my.gl-namespace: the privileged wrapper security.wrappers.${n} (${
              lib.concatStringsSep ", " (
                lib.optional privileged.${n}.setuid "setuid"
                ++ lib.optional privileged.${n}.setgid "setgid"
                ++ lib.optional (privileged.${n}.capabilities != "") privileged.${n}.capabilities
              )
            }) loads GL (${lib.concatStringsSep ", " hits}).
            In a mapped user's namespace /run/opengl-driver is THEIR tree, so this
            wrapper would run code the user controls with its privileges.
            Disable it (security.wrappers.${n}.enable = lib.mkForce false;), or
            accept it with a reason in my.gl-namespace.allowPrivilegedGL.${n}.'';
        }) glWrappers;
    })

    (lib.mkIf active {
      environment.etc."security/namespace.conf".text = namespaceConf;

      security.pam.services = lib.genAttrs cfg.pamServices (svc: {
        rules.session = {
          # Before pam_namespace, in the root namespace: point the instance
          # at the current generation's tree. optional: a failure logs and
          # leaves the last selection (or the system's tree).
          gl-driver-select = {
            order = config.security.pam.services.${svc}.rules.session.unix.order + 58;
            control = "optional";
            modulePath = "${config.security.pam.package}/lib/security/pam_exec.so";
            args = [
              "quiet"
              "type=open_session"
              "${select}"
            ];
          };
          # Same rule, same values as guest-overlay's: with both features on
          # they merge into one pam_namespace reading both namespace.conf parts.
          namespace = {
            order = config.security.pam.services.${svc}.rules.session.unix.order + 60;
            control = "required";
            modulePath = "${config.security.pam.package}/lib/security/pam_namespace.so";
          };
        };
      });

      systemd.tmpfiles.settings.graphics-driver =
        {
          "/run/opengl-driver" = lib.mkForce { "L+".argument = "${root}/view/tree"; };
          "${root}/system"."L+".argument = toString driversEnv;
        }
        // lib.optionalAttrs has32 {
          "/run/opengl-driver-32" = lib.mkForce { "L+".argument = "${root}/view/tree-32"; };
          "${root}/system-32"."L+".argument = toString driversEnv32;
        };

      systemd.tmpfiles.settings.gl-namespace =
        {
          ${root}.d = { mode = "0755"; user = "root"; group = "root"; };
          "${root}/view".d = { mode = "0755"; user = "root"; group = "root"; };
          "${root}/view/tree"."L+".argument = "${root}/system";
          "${root}/inst".d = { mode = "0000"; user = "root"; group = "root"; };
          ${gcroots}.d = { mode = "0755"; user = "root"; group = "root"; };
        }
        // lib.optionalAttrs has32 {
          "${root}/view/tree-32"."L+".argument = "${root}/system-32";
        }
        # Seed each instance with the system's tree: `L`, not `L+`, so an
        # activation never overwrites a user's selection, and a failed select
        # still leaves a working view.
        // lib.listToAttrs (
          lib.concatMap (
            n:
            [
              (lib.nameValuePair "${root}/inst/${n}" { d = { mode = "0755"; user = "root"; group = "root"; }; })
              (lib.nameValuePair "${root}/inst/${n}/tree" { L.argument = "${root}/system"; })
            ]
            ++ lib.optional has32 (lib.nameValuePair "${root}/inst/${n}/tree-32" { L.argument = "${root}/system-32"; })
          ) cfg.users
        );

      # A home switch repoints the user's tree without a re-login.
      systemd.services."gl-driver-select@" = {
        description = "Select the graphics driver tree of %i's home generation";
        after = [ "systemd-tmpfiles-setup.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${select} %i";
        };
      };
      systemd.paths = lib.listToAttrs (
        map (n: {
          name = "gl-driver-select-${n}";
          value = {
            description = "Watch ${n}'s home-manager profile for a new graphics driver tree";
            wantedBy = [ "multi-user.target" ];
            pathConfig = {
              PathChanged = [
                "${config.users.users.${n}.home}/.local/state/nix/profiles/home-manager"
                "/nix/var/nix/profiles/per-user/${n}/home-manager"
              ];
              Unit = "gl-driver-select@${n}.service";
            };
          };
        }) cfg.users
      );

      environment.systemPackages = [ gl-system-driver ];
    })
  ];
}
