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
        fingers on the touchscreen belong to the compositor (trapezoid.patch's
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
      default = [
        # nfingers,gesture,edge,distance,command -- DU means down-to-up, i.e.
        # swiping upward. Vertical to match the touchpad's `4, vertical,
        # workspace` binding and the slidevert workspace animation.
        # Lua dispatch form: with wayland.windowManager.hyprland.configType =
        # "lua" (features/hyprland/home.nix), `hyprctl dispatch` no longer
        # parses legacy dispatcher strings -- "workspace e+1" dies with
        # "')' expected near 'e'" because the argument is evaluated as Lua
        # (hyprctl's own hint: "dispatch in lua is a shorthand for
        # hl.dispatch(...)"). The table has one field, so no commas -- which
        # matters, commas would split this lisgd -g spec.
        # RELATIVE, NOT e-RELATIVE. "e+1"/"e-1" walk only workspaces that
        # already EXIST, so swiping up from workspace 10 with nothing above it
        # wrapped back to 1 -- measured. That put the swipes at odds with the
        # keybinds and made every page past the first unreachable by touch; see
        # the paged strip in features/dms/plugins/workspaces. Plain "+1"/"-1"
        # step into empty workspaces, creating them on demand, and "-1" clamps
        # at workspace 1 rather than running negative.
        # Now the SAME logic the Mod+J/K keybinds and the touchpad's vertical
        # swipe use: walk the column first, change workspace only at its end.
        # Previously these dispatched focus{workspace=...} directly, which
        # matched the keys but not the touchpad's built-in `workspace` gesture
        # -- the three disagreed most visibly on a blank workspace.
        #
        # HyprFocusOrWorkspace is a global Lua function defined in the compositor
        # config (features/hyprland/home.nix), so this is `eval`, not `dispatch`:
        # dispatch is shorthand for hl.dispatch(...) and only takes a dispatcher,
        # while eval runs arbitrary Lua in the config's own state. Calling it
        # there rather than reimplementing keeps one copy of the behaviour, and
        # costs only this one IPC round-trip -- unavoidable from an external
        # daemon, but far cheaper than spawning an interpreter per swipe.
        # DU (swiping upward) pairs with Mod+J, i.e. "down" the column.
        "${toString cfg.fingers},DU,*,*,hyprctl eval 'HyprFocusOrWorkspace(\"down\")'"
        "${toString cfg.fingers},UD,*,*,hyprctl eval 'HyprFocusOrWorkspace(\"up\")'"
        # Horizontal swipes walk the scrolling layout's tape, same dispatcher
        # as the Mod+H/L keybinds (features/hyprland/home.nix) -- column data
        # structure, not geometry, so it works on maximized windows too.
        # lisgd is not limited to workspace switching: every gesture is just
        # a command, so anything hyprctl can dispatch works here.
        "${toString cfg.fingers},RL,*,*,hyprctl dispatch 'hl.dsp.layout(\"focus r\")'"
        "${toString cfg.fingers},LR,*,*,hyprctl dispatch 'hl.dsp.layout(\"focus l\")'"
      ];
      defaultText = lib.literalExpression ''vertical workspace switching on `fingers` fingers'';
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

    systemd.user.services.lisgd = {
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
