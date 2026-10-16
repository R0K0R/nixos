{ config, lib, inputs, ... }:

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
    keystone.enable = lib.mkEnableOption ''
      EXPERIMENTAL per-window perspective-trapezoid rendering for windows tagged
      "dock" (my.sidedock). Builds the compositor from the fork's `keystone`
      branch (the overlay below; rendering from sihooleebd/nixos): the texture
      vertex shaders honour a projective w, and renderTextureInternal
      post-multiplies a yaw homography into the projection for dock windows;
      every other window renders as before. Touches the same renderer as the
      fork's blur and rotation fixes -- check a rotated output'';

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
      how it is laid out): `nixos` = nixpkgs' tag + the local bug fixes, each
      also on its own pr/* branch; `keystone` = that + the side-dock series.
      It replaced a stack of patch files here (layoutmanager null space, gamma
      zombie, input on monitor loss, soft-apply blur, keystone/01..11); each is
      now one commit in the fork, its old header the commit message.

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
          branch = if config.my.hyprland.keystone.enable then "keystone" else "nixos";
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
    };
  };
}
