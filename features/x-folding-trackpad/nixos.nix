{ config, lib, pkgs, ... }:

let
  cfg = config.my.x-folding-trackpad;
  python = pkgs.python3.withPackages (ps: [ ps.evdev ]);
  vendor = "04e8";
  product = "7021";
in
{
  /*
    Natural scrolling for the X-Folding RGB Bluetooth keyboard's trackpad,
    without inverting its pinch-zoom.

    The trackpad is not a touchpad to Linux. Its firmware reports no touches:
    a two-finger swipe arrives as mouse-wheel events, and a pinch as Ctrl plus
    wheel (captured with libinput -- no GESTURE_PINCH anywhere, 23
    LEFTCTRL press/release pairs each wrapping a burst of wheel events). A
    compositor-side natural_scroll therefore flips both, and every app's
    Ctrl+wheel zoom runs backwards.

    ./filter.py sits in front of the device instead: it inverts the wheel for
    scrolling and leaves it alone while the firmware's Ctrl is held. See its
    header for the hold-back that handles a pinch's first wheel events
    arriving before its Ctrl.

    Plumbing:
    - udev starts one filter instance per connection (Bluetooth: no stable
      /dev/input/by-* link, so it is matched by name and id) and BindsTo stops
      it on disconnect. The filter's own output ("... (filtered)", product
      f021) does not match the rule, so it cannot trigger itself.
    - The filter grabs the raw node exclusively and re-emits through uinput.
      keyd is told to skip the raw 04e8:7021 node so it grabs the filter's
      device instead, keeping its remaps on this keyboard.
    - features/hyprland turns its global input:natural_scroll off whenever
      this is enabled; otherwise the wheel would be inverted twice.

    Failure mode, if the filter is not running: keyd skips the raw device and
    nothing grabs it, so Hyprland reads it directly -- scrolling reverts to
    the unnatural direction and keyd's remaps do not apply to this keyboard.
    Nothing worse.
  */
  options.my.x-folding-trackpad.enable = lib.mkEnableOption ''
    natural scrolling for the X-Folding RGB keyboard's trackpad that leaves
    its Ctrl+wheel pinch-zoom unaffected
  '';

  config = lib.mkIf cfg.enable {
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="X-Folding RGB", ATTRS{id/vendor}=="${vendor}", ATTRS{id/product}=="${product}", TAG+="systemd", ENV{SYSTEMD_WANTS}+="x-folding-trackpad@%k.service"
    '';

    systemd.services."x-folding-trackpad@" = {
      description = "X-Folding RGB trackpad filter on %I";
      bindsTo = [ "dev-input-%i.device" ];
      after = [ "dev-input-%i.device" ];
      serviceConfig = {
        ExecStart = "${python}/bin/python3 ${./filter.py} /dev/input/%I";
        Restart = "on-failure";
        RestartSec = 1;
      };
    };

    # The udev rule only fires on "add". A keyboard already connected when
    # this is first switched to would sit unfiltered, and keyd skips the raw
    # node, so it loses every remap. Attach to whatever is present on boot
    # and on each switch that changes the filter.
    systemd.services.x-folding-trackpad-attach = {
      description = "Attach the X-Folding RGB filter to already-connected devices";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" ];
      restartTriggers = [ ./filter.py python ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for e in /sys/class/input/event*; do
          [ "$(cat "$e/device/name" 2>/dev/null)" = "X-Folding RGB" ] || continue
          [ "$(cat "$e/device/id/vendor")" = "${vendor}" ] || continue
          [ "$(cat "$e/device/id/product")" = "${product}" ] || continue
          systemctl start --no-block "x-folding-trackpad@$(basename "$e").service"
        done
      '';
    };

    # Skip the raw node; keyd picks up the filter's output through "*".
    services.keyd.keyboards.default.ids = lib.mkIf config.services.keyd.enable (lib.mkAfter [
      "-${vendor}:${product}"
    ]);
  };
}
