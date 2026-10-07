{ config, lib, ... }:

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
      "dock" (my.sidedock). Patches the compositor (./patches/keystone/, from
      sihooleebd/nixos): the texture vertex shaders honour a projective w, and
      renderTextureInternal post-multiplies a yaw homography into the projection
      for dock windows; every other window renders as before. Touches the same
      renderer as the blur and rotation patches here -- check a rotated output'';

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
      A crash fix carried locally until it is upstream.

      Hyprland 0.56.2 segfaults on a three-finger trackpad swipe -- the `move`
      gesture configured in this feature's home half -- whenever the focused
      window is floating and its layout target has no space. Four identical
      crashes here (2026-08-04 x2, 2026-09-16, 2026-09-23), every one of them:

        CMoveTrackpadGesture::update
          Layout::CLayoutManager::moveTarget
            Layout::CSpace::moveTarget     <- SEGV at +0x15

      The null is the SPACE, not the window: MoveGesture.cpp already returns
      early on a null window, and entering CSpace::moveTarget through an empty
      SP<CSpace> faults on its first member read. LayoutManager.cpp already
      guards exactly this in changeFloatingMode() and moveTargetInDirection(),
      so moveTarget() is simply missing the check its siblings have.

      Expect this to FAIL LOUDLY on a nixpkgs bump that moves the file -- which
      is the point. When it does, check whether upstream has fixed it and drop
      the patch rather than rebasing it by reflex.
    */
    nixpkgs.overlays = [
      (final: prev: {
        hyprland = prev.hyprland.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ [
            ./layoutmanager-guard-null-space.patch
            # Night mode dead until Hyprland restarts: one refused gamma
            # control request left a zombie that claimed eDP-1 for good.
            # See the patch header.
            ./gamma-refused-control-zombie.patch
            # Touchscreen workspace swipe crashing (SIGSEGV in end()/update())
            # when its monitor vanishes mid-gesture -- reachable here because
            # the lid-close handler disables eDP-1. See the patch header.
            ./swipe-abandon-on-monitor-loss.patch
            # Blur behind windows kept the pre-rotation orientation: the soft
            # rule-apply path (rotation) never dirtied the pre-blurred cache.
            # Applies after the fork's monitor-soft-apply-logical-size.patch,
            # which edits the same function.
            ./soft-apply-mark-blur-dirty.patch
          ]
          # Perspective-trapezoid rendering for side-dock windows and the dock's
          # input/gesture support, as an ordered series (patches/keystone/README);
          # see the keystone option. Rendering from sihooleebd/nixos (1d5e9bf).
          ++ lib.optionals config.my.hyprland.keystone.enable [
            ./patches/keystone/01-keystone-render.patch
            ./patches/keystone/02-scale-to-fit.patch
            ./patches/keystone/03-keystone-input.patch
            ./patches/keystone/04-dock-move-gestures.patch
            ./patches/keystone/05-dock-bounce-curves.patch
            ./patches/keystone/06-gesture-handoff.patch
            ./patches/keystone/07-keystone-overview.patch
            ./patches/keystone/08-lua-touch-pen-events.patch
            ./patches/keystone/09-special-recentre-exemption.patch
            ./patches/keystone/10-touch-pen-border-resize.patch
            ./patches/keystone/11-touchscreen-swipes.patch
          ];
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
