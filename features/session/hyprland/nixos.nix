{ config, lib, pkgs, inputs, ... }:

{
  /*
    EXTENSION POINTS, so that features/hyprland can be about Hyprland.

    It used to hard-code DankMaterialShell: the transform shim called DMS's
    bar-swap script by store path, and roughly fifteen keybinds ran `dms ipc`.
    A host running Hyprland with no shell got a config full of binds that
    spawned nothing, and swapping shells meant editing the compositor.

    The dependency now points the other way. Anything wanting compositor
    configuration contributes it -- keybinds and rules through home-manager's
    own merging (wayland.windowManager.hyprland.extraConfig is types.lines, and
    settings is a freeform attrsOf, so definitions from any number of modules
    concatenate into the one generated hyprland.lua) and rotation behaviour
    through the option below, which is the one case merging cannot express
    because the value is consumed by a shell script rather than by the config.
  */
  options.my.hyprland = {
    modKey = lib.mkOption {
      type = lib.types.str;
      default = "SUPER";
      description = ''
        The modifier every keybind is expressed against.

        An option rather than the `local mod = "SUPER"` this used to be. That
        local still exists in the generated Lua, and a fragment appended by
        another feature can technically see it -- one file, one chunk, locals
        visible to everything below them. But that is a contract enforced by
        nothing except concatenation order: reorder the fragments and every
        contributed bind silently binds against nil. Interpolating one Nix
        value into both places makes the agreement explicit and order-proof.
      '';
    };

    rotationHooks = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression "[ (pkgs.writeShellScript \"swap-bar\" \"...\") ]";
      description = ''
        Executables run on every screen rotation, each with the new transform
        (0-7) as its only argument.

        WHY AN OPTION AND NOT A KEYBIND. Rotation is not a keypress -- it
        arrives from iio-hyprland as a batch of legacy `hyprctl keyword`
        commands, which the shim in this feature's home half intercepts and
        rewrites. Anything that must react has to be called from inside that
        shim, so the shim needs a list it can iterate instead of a store path
        compiled into it.

        RUN BEFORE the real hyprctl call, and deliberately: the shim `exec`s
        into hyprctl, so a hook placed after it would never run at all. Hooks
        are also best-effort -- a failure is swallowed -- because a shell that
        is not up yet must not turn a rotation into a broken screen.

        Ordering between hooks is list order. Nothing here should depend on
        another hook having run.
      '';
    };
  };

  config = lib.mkIf (config.my.desktop.compositor == "hyprland") {
    /*
      Hyprland from the R0K0R/Hyprland fork (features/hyprland/flake.nix says
      how it is laid out): its `nixos` branch, nixpkgs' tag + the local bug
      fixes, each also on its own pr/* branch. It replaced a stack of patch
      files here (layoutmanager null space, gamma zombie, input on monitor
      loss, soft-apply blur); each is now one commit in the fork, its old
      header the commit message.

      This is the host's compositor: the greeter's, the portal's and that of
      any account whose home brings none. A patched one (the keystone series,
      a user's own patch) is a home's my.hyprland.package; the session entry
      below starts it.

      patches = [ ]: nixpkgs' own patch (monitor-soft-apply-logical-size, from
      the nixpkgs fork) is a commit in the fork too and would not apply twice.

      FAILS LOUDLY when nixpkgs moves Hyprland off the fork's base tag: the rest
      of the toolchain (hyprutils, aquamarine, ...) moves with it, so rebase the
      fork onto the new tag -- dropping fixes upstream has taken -- and bump
      forkBase, rather than building an old Hyprland against new libraries.
    */
    nixpkgs.overlays = [
      (final: prev:
        let
          forkBase = "0.56.2";
          branch = "nixos";
          src = inputs.feat-hyprland.src.${branch};
        in
        {
          hyprland =
            assert lib.assertMsg (prev.hyprland.version == forkBase)
              "features/hyprland: nixpkgs has Hyprland ${prev.hyprland.version}, the R0K0R/Hyprland fork is based on ${forkBase} -- rebase the fork";
            prev.hyprland.overrideAttrs (old: {
              inherit src;
              patches = [ ];
              # shown in `hyprctl version`
              env = old.env // {
                GIT_BRANCH = branch;
                GIT_COMMIT_HASH = src.rev;
                GIT_COMMIT_DATE = toString src.lastModified;
              };
              # upstream's points at finalAttrs.src.tag, which a flake input has not got
              meta = old.meta // { changelog = "https://github.com/R0K0R/Hyprland/commits/${branch}"; };
            });
        })
    ];

    programs.hyprland = {
      enable = true;
      # DMS greeter launches hyprland.desktop via uwsm regardless of this flag's
      # own default. Without withUWSM, programs.uwsm.enable never fires, so the
      # systemd user units uwsm needs (wayland-session-bindpid@.service etc.)
      # are missing -> "systemctl --user start ... exit status 5" crash loop.
      withUWSM = true;

      /*
        The session entry starts the logged-in account's compositor. A home's
        my.hyprland.package lands in its profile; when that Hyprland is not this
        one, hyprland.desktop runs the profile's start-hyprland with --path (its
        default execvp("Hyprland") would find /run/wrappers/bin/Hyprland, this
        build, first). Otherwise this build, through the cap_sys_nice wrapper as
        before -- a profile's own binary runs without it (no SCHED_RR).

        A symlinkJoin, so the session change rebuilds nothing. The uwsm entry
        resolves hyprland.desktop through the user's data dirs, where a home's
        own Hyprland package shadows this one; the greeter remembers the plain
        entry.

        Overridable like the package it wraps: the module's apply calls
        .override { enableXWayland, withUWSM }, which reaches the real build.
      */
      package = lib.makeOverridable (
        args:
        let
          real = pkgs.hyprland.override args;
          launcher = pkgs.writeShellScript "hyprland-session" ''
            sys=$(${pkgs.coreutils}/bin/readlink -f ${real}/bin/Hyprland)
            for p in "$HOME/.nix-profile/bin" "/etc/profiles/per-user/''${USER:-$(${pkgs.coreutils}/bin/id -un)}/bin"; do
              h=$(${pkgs.coreutils}/bin/readlink -f "$p/Hyprland" 2>/dev/null) || continue
              if [ -x "$h" ] && [ "$h" != "$sys" ] && [ -x "$p/start-hyprland" ]; then
                exec "$p/start-hyprland" --path "$h" "$@"
              fi
            done
            exec ${real}/bin/start-hyprland "$@"
          '';
        in
        pkgs.symlinkJoin {
          inherit (real) pname version;
          # one output, not real's out + man
          meta = removeAttrs real.meta [ "outputsToInstall" ];
          paths = [ real ];
          postBuild = ''
            ln -s ${launcher} $out/bin/hyprland-session
            rm $out/share/wayland-sessions/hyprland.desktop
            substitute ${real}/share/wayland-sessions/hyprland.desktop $out/share/wayland-sessions/hyprland.desktop \
              --replace-fail "Exec=${real}/bin/start-hyprland" "Exec=$out/bin/hyprland-session"
          '';
          passthru = real.passthru // { unwrapped = real; };
        }
      ) { };
    };
  };
}
