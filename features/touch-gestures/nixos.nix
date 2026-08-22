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
      default = 3;
      description = ''
        Finger count for the default gestures. Three is deliberate: lisgd does
        not grab the device, so one- and two-finger swipes fire *in addition* to
        whatever the application does with them.
      '';
    };

    orientation = lib.mkOption {
      type = lib.types.enum [ "normal" "left" "right" "inverted" ];
      default = "normal";
      description = ''
        Screen orientation lisgd should assume, passed as `-o`.

        Static, which is a real limitation on a convertible: this machine
        autorotates via iio-hyprland, and lisgd will not follow. Gestures are
        rotated with the panel until it returns to this orientation. Nothing
        here fixes that; it is recorded so the behaviour is not a surprise.
      '';
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
        "${toString cfg.fingers},DU,*,*,hyprctl dispatch 'hl.dsp.focus({ workspace = \"e+1\" })'"
        "${toString cfg.fingers},UD,*,*,hyprctl dispatch 'hl.dsp.focus({ workspace = \"e-1\" })'"
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

  config = lib.mkIf cfg.enable {
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
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe pkgs.lisgd)
            "-d"
            cfg.device
            "-o"
            cfg.orientation
          ]
          ++ lib.concatMap (g: [ "-g" g ]) cfg.gestures
        );
        Restart = "on-failure";
        RestartSec = 5;
      };

      # hyprctl, and whatever else a gesture command reaches for.
      path = [ pkgs.hyprland ];
    };
  };
}
