{ config, lib, pkgs, ... }:

let
  cfg = config.my.embedded-keyboard;
  unitName = "embedded-keyboard-disabled";

  toggle = pkgs.writeShellScript "embedded-keyboard-${cfg.serioDevice}" ''
    set -eu
    dev=${lib.escapeShellArg cfg.serioDevice}
    drv=${lib.escapeShellArg cfg.driver}
    node=/sys/bus/serio/devices/$dev

    # drvctl, NOT the driver's bind/unbind files. Writing $dev to
    # /sys/bus/serio/drivers/atkbd/unbind is accepted by the kernel and the
    # port is then immediately re-probed and rebound, so the keyboard keeps
    # working while the unit exits 0 -- measured, that is exactly what the
    # first version of this did. serio ports take "none" on drvctl to detach
    # without a re-probe, and a driver name to attach.
    #
    # Every branch then CHECKS THE EFFECT rather than trusting the write, for
    # the same reason: a toggle that reports a disabled keyboard you can still
    # type on is worse than one that fails.
    case "''${1:-}" in
      detach)
        if [ -e "$node/driver" ]; then
          # bind_mode FIRST. Its default is "auto", under which the kernel
          # re-probes the port and rebinds atkbd moments after the detach --
          # measured: the unit detached, verified a driverless port, exited 0,
          # and the keyboard was bound again by the time anyone looked. Setting
          # "manual" is what makes the detach stick.
          printf 'manual' > "$node/bind_mode"
          printf 'none' > "$node/drvctl"
          # Settle before checking: the rebind that defeated the previous
          # version was asynchronous, so an immediate check saw success.
          ${pkgs.coreutils}/bin/sleep 0.5
          if [ -e "$node/driver" ]; then
            echo "drvctl accepted 'none' but $dev is still bound to $(basename "$(readlink -f "$node/driver")")" >&2
            exit 1
          fi
        fi
        ;;
      attach)
        # Restore bind_mode even if the port already has a driver, so a
        # half-applied state cannot leave the port pinned to manual forever.
        printf 'auto' > "$node/bind_mode"
        if [ ! -e "$node/driver" ]; then
          printf '%s' "$drv" > "$node/drvctl"
          ${pkgs.coreutils}/bin/sleep 0.5
          if [ ! -e "$node/driver" ]; then
            echo "drvctl accepted '$drv' but $dev came back with no driver" >&2
            exit 1
          fi
        fi
        ;;
    esac
  '';
in
{
  /*
    Temporarily disable the BUILT-IN keyboard, from the control centre.

    WHY THIS LIVES IN THE KERNEL AND NOT IN THE COMPOSITOR. The natural
    `device[at-translated-set-2-keyboard]:enabled = false` does nothing on this
    machine: keyd runs with `[ids] *`, so it grabs every physical keyboard and
    re-emits through keyd-virtual-keyboard, and that virtual device is what
    Hyprland receives from. Disabling it would take every EXTERNAL keyboard
    down too -- the exact opposite of what this is for. A second EVIOCGRAB is
    not available either, since keyd already holds the exclusive grab.

    Detaching the i8042 port via its drvctl removes the evdev node outright,
    below everything that could be holding it. keyd follows device removal and
    re-grabs on rebind, so its remaps come back with the keyboard.

    The state is deliberately NOT persistent: the unit is wantedBy nothing, so
    a reboot always gives the keyboard back. That is the safety net for the
    obvious hazard of this feature -- turning off the keyboard you would use to
    turn it back on.
  */
  options.my.embedded-keyboard = {
    enable = lib.mkEnableOption ''
      a control-centre toggle that unbinds the built-in keyboard.

      Pairs with the embeddedKeyboard DMS plugin
      (features/dms/plugins/embedded-keyboard), which is the UI for the unit
      this defines; the unit is usable on its own with
      `systemctl start/stop ${unitName}`
    '';

    serioDevice = lib.mkOption {
      type = lib.types.str;
      default = "serio0";
      description = ''
        The serio port of the built-in keyboard, as named under
        /sys/bus/serio/devices.

        Find it with the driver, not by guessing the number:

          for d in /sys/bus/serio/devices/serio*; do
            [ "$(basename "$(readlink -f "$d/driver")")" = atkbd ] && echo "$d"
          done

        On this machine that is serio0 ("i8042 KBD port", backing
        /devices/platform/i8042/serio0/input/input0, the AT Translated Set 2
        keyboard). The touchpad is a separate serio port under psmouse and is
        unaffected.
      '';
    };

    driver = lib.mkOption {
      type = lib.types.str;
      default = "atkbd";
      description = ''
        Driver to re-attach on restore, written to the port's drvctl. The
        keyboard half of i8042 is atkbd; the touchpad half is psmouse.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = config.my.internal.primaryUser;
      defaultText = lib.literalExpression "the primary user";
      description = "User whose local, active session may toggle the unit without a password prompt.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.${unitName} = {
      description = "Built-in keyboard disabled (serio port detached via drvctl)";
      # Started on demand only. Nothing wants it, so it never survives a boot.
      unitConfig.ConditionPathExists = "/sys/bus/serio/drivers/atkbd";
      serviceConfig = {
        Type = "oneshot";
        # The disable IS the unit's running state: stopping it rebinds.
        RemainAfterExit = true;
        ExecStart = "${toggle} detach";
        ExecStop = "${toggle} attach";
      };
    };

    /*
      One unit, one user, one session. Scoped this tightly on purpose: the
      generic "let wheel manage units" rule would hand the desktop every
      system unit to satisfy a keyboard toggle.
    */
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units"
              && action.lookup("unit") == "${unitName}.service"
              && ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0
              && subject.user == "${cfg.user}"
              && subject.local && subject.active) {
              return polkit.Result.YES;
          }
      });
    '';
  };
}
