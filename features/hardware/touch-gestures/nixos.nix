{ config, lib, pkgs, ... }:

let
  cfg = config.my.touch-gestures;
in
{
  /*
    Multi-finger gestures on the TOUCHSCREEN, via lisgd.

    Why a separate daemon rather than compositor config: Hyprland's `gesture =`
    bindings are libinput GESTURE events, which only touchpads emit. A
    touchscreen emits touch events, and libinput never synthesises swipes from
    them. Hyprland 0.56 has exactly one touchscreen gesture --
    `gestures:workspace_swipe_touch`, a single-finger swipe from the screen edge
    -- and its activation strip is `(gaps_out + border_size) / screen_height`,
    which on this config is gaps_out=4, border_size=0, i.e. FOUR PIXELS. Real
    enough to enable, far too small to aim at.

    lisgd reads the evdev device directly and synthesises swipes from raw touch
    events, which is the thing libinput declines to do. It observes rather than
    grabs, so the application underneath still receives the touches -- fine for
    3-finger gestures, a reason to be careful about 1- and 2-finger ones.
  */
  options.my.touch-gestures = {
    enable = lib.mkEnableOption "multi-finger touchscreen gestures via lisgd";

    device = lib.mkOption {
      type = lib.types.str;
      example = "/dev/input/by-path/pci-0000:00:15.1-platform-i2c_designware.1-event";
      description = ''
        evdev node of the touchscreen.

        Required, with no default, and it belongs in the host file: this is a
        PCI path, a property of one machine's hardware.

        Use a /dev/input/by-path/ symlink, never a bare /dev/input/eventN --
        event numbers are assigned in probe order and move between boots.

        To find it: the touchscreen is the device whose /proc/bus/input/devices
        block has `B: PROP=2` (INPUT_PROP_DIRECT) together with the multitouch
        ABS bits. Do not grep for "touch" in the name -- on this machine the
        panel is a Goodix reporting as `GXTP7936:00 27C6:0123`, with the word
        nowhere in it, while the only device that DOES say Touchpad is the
        touchpad.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.my.internal.primaryUser;
        defaultText = lib.literalExpression "the primary user";
      description = "User whose session runs the daemon, and who is added to the `input` group.";
    };

    fingers = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = ''
        Finger count for the default gestures. lisgd does not grab the device,
        so one- and two-finger swipes would fire *in addition* to whatever the
        application does with them. Four, not three, since 2026-10-08: three
        fingers on the touchscreen belong to the compositor (the Hyprland fork's keystone touchscreen-swipes commit's
        3-finger double-tap-and-drag live move), whose drag lisgd would also
        read as a swipe -- and four matches the touchpad, where the vertical
        4-finger swipe walks the column and changes workspace too.
      '';
    };

    orientation = lib.mkOption {
      type = lib.types.enum [ "normal" "left" "right" "inverted" ];
      default = "normal";
      description = ''
        Screen orientation lisgd assumes until a rotation has been recorded.
        After that it follows the panel: a rotation hook (features/hyprland's
        rotationHooks) records each new transform and restarts lisgd with the
        matching `-o`, since lisgd only maps edges and directions at start-up.
      '';
    };

    followRotation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether gesture directions and edges follow the screen rotation (the
        `orientation` fallback, then each recorded transform). false pins them to
        the panel's PHYSICAL frame -- lisgd at -o 0, which is the touchscreen's
        raw frame -- for gestures tied to a physical edge rather than to the
        picture, e.g. features/sidedock's dock, which lives on the panel's
        physical right edge at every rotation.
      '';
    };

    # For other features to ADD gestures. Defining `gestures` itself from a feature would
    # replace the defaults wholesale (a list option's default applies only when nothing
    # defines it); this one merges, and is appended after them.
    extraGestures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Further lisgd `-g` specs, appended to `gestures`; same format.";
    };
    gestures = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      /*
        EMPTY since 2026-10-08: the compositor now runs the touchpad's own
        gestures for the touchscreen, live (Hyprland fork, keystone touchscreen-swipes:
        4 fingers -> the column walk with its workspace handoff and scroll_move;
        3-finger tap-then-drag -> the move gesture). lisgd could only fire a
        command at release, and running both would act twice per swipe. What it
        used to bind, for the record -- 4 fingers, each a hyprctl call:
          DU/UD  hyprctl eval 'HyprFocusOrWorkspace("down"/"up")'  (Mod+J/K logic)
          RL/LR  hyprctl dispatch 'hl.dsp.layout("focus r"/"focus l")'
        Commands run through `hyprctl eval` for Lua functions (eval runs Lua in
        the config's state; dispatch only takes a dispatcher), and a -g spec
        must not contain commas. Features still add edge swipes through
        extraGestures (features/sidedock: the dock).
      */
      default = [ ];
      defaultText = lib.literalExpression "[ ]";
      description = ''
        Raw lisgd `-g` specs: `nfingers,gesture,edge,distance[,actmode],command`.

        gesture   LR RL DU UD DLUR DRUL URDL ULDR
        edge      * (any) N (none) L R T B TL TR BL BR
        distance  * (any) S M L
        actmode   R (release, default) or P (pressed)

        Deliberately NOT a full mirror of the touchpad set. `3, swipe, move` and
        `4, horizontal, scrollMove` are Hyprland-internal gestures driving live
        animated drags; lisgd can only fire a command on completion, so a
        one-to-one port would be a worse imitation than not having it.
      '';
    };
  };

  config = lib.mkIf cfg.enable (let
    /*
      lisgd FOLLOWS THE ROTATION. It maps edges and swipe directions through its
      orientation once, at start-up, so after an autorotate the right-edge gesture fired
      from a different physical edge. So: a rotation hook records the new transform and
      restarts the daemon, and this wrapper starts it with -o for the CURRENT transform.
      Mapping as lisgd's own wl_output handler does (lisgd.c display_handle_geometry):
      Hyprland/wl_output transform 1 (90 deg) is lisgd 3, transform 3 is lisgd 1. The
      static `orientation` option is the fallback before any rotation was recorded.

      -w/-h are passed too, and that matters: without them lisgd asks Wayland for the
      screen size AND takes the output's transform from the same reply, overriding -o.
      The rotation hook restarts it while the panel is still turning, so it latched the
      rotated transform and kept it -- in landscape, swipes acted as if the laptop were
      turned (workspace swipes horizontal, the dock edge at the bottom). 2026-10-07.
      The size is the output's mode, untransformed, as lisgd's own mode handler reads it.
    */
    staticOrientation = { normal = 0; right = 1; inverted = 2; left = 3; }.${cfg.orientation};
    lisgdStart = pkgs.writeShellScript "lisgd-start" ''
      t=""
      [ -r "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lisgd.transform" ] && t=$(cat "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lisgd.transform")
      [ -z "$t" ] && [ -r "''${XDG_STATE_HOME:-$HOME/.local/state}/hypr/transform-${config.my.desktop.primaryOutput}" ] \
        && t=$(cat "''${XDG_STATE_HOME:-$HOME/.local/state}/hypr/transform-${config.my.desktop.primaryOutput}")
      case "$t" in
        1) o=3 ;; 3) o=1 ;; 2) o=2 ;; 0) o=0 ;;
        *) o=${toString staticOrientation} ;;
      esac
      ${lib.optionalString (!cfg.followRotation) "o=0  # followRotation = false: the panel's physical frame"}
      size=$(${config.programs.hyprland.package}/bin/hyprctl monitors -j 2>/dev/null \
        | ${lib.getExe pkgs.jq} -r '(.[] | select(.name == "${config.my.desktop.primaryOutput}")) // .[0] | "-w \(.width) -h \(.height)"' 2>/dev/null)
      # shellcheck disable=SC2086 # $size is two flag pairs, or empty (falls back to Wayland)
      exec ${lib.escapeShellArgs [ (lib.getExe pkgs.lisgd) "-d" cfg.device ]} -o "$o" $size ${
        lib.escapeShellArgs (lib.concatMap (g: [ "-g" g ]) (cfg.gestures ++ cfg.extraGestures))
      }
    '';
    reorient = pkgs.writeShellScript "lisgd-reorient" ''
      printf '%s\n' "$1" > "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lisgd.transform"
      systemctl --user try-restart lisgd.service
    '';
  in {
    # Run on every screen rotation (features/hyprland), with the new transform.
    my.hyprland.rotationHooks = [ reorient ];

    # /dev/input/event* is root:input 0660.
    users.users.${cfg.user}.extraGroups = [ "input" ];

    environment.systemPackages = [ pkgs.lisgd ];

    # Only with something to do: given no -g at all, lisgd falls back to its
    # compiled-in default gestures (lisgd.c, gestsarrlen == 0), not to nothing.
    systemd.user.services.lisgd = lib.mkIf (cfg.gestures ++ cfg.extraGestures != [ ]) {
      description = "Touchscreen gesture daemon (lisgd)";
      # Needs the compositor up: every gesture runs hyprctl against its socket.
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lisgdStart;
        Restart = "on-failure";
        RestartSec = 5;
      };

      # hyprctl, and whatever else a gesture command reaches for.
      path = [ pkgs.hyprland ];
    };
  });
}
