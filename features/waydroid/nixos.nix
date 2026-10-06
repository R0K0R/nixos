# Waydroid: Android in LXC/Wayland. Uses NixOS's built-in module
# (`virtualisation.waydroid` -> pulls `virtualisation.lxc`, binder kernel config
# checks, systemd unit).
{ config, lib, pkgs, ... }:

let
  cfg = config.my.waydroid;
in
{
  options.my.waydroid = {
    enable = lib.mkEnableOption "Waydroid (Android compatibility layer)";

    /* When autoAdb is true, switches `auto_adb = False` → `True` in /var/lib/waydroid/waydroid.cfg on
       `nixos-rebuild` if the line is exactly `auto_adb = False`. This is the documented knob
       for painless host adb (Flutter: `flutter run -d …`). Turn off if you manage cfg yourself. */
    autoAdb = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Align Waydroid with host ADB tooling by enabling `auto_adb` in waydroid.cfg.
        With `ro.adb.secure=1` you may still need Developer options → USB debugging and one RSA approval in the Waydroid UI the first time.
      '';
    };

    suspendAction = lib.mkOption {
      type = lib.types.enum [ "freeze" "stop" ];
      default = "freeze";
      description = ''
        What the host does when Android asks to suspend, written to
        `suspend_action` in waydroid.cfg.

        READ THIS BEFORE REACHING FOR IT TO KEEP BACKGROUND AUDIO ALIVE: it
        cannot do that. Waydroid 1.6.3's hardware_manager.suspend() is

          if suspend_action == "stop": session_manager.stop()
          else:                        container_manager.freeze()

        so every value that is not "stop" falls through to freeze -- there is
        no "none", and inventing one just picks the default the long way.
        Freezing is the cgroup freezer over the whole container, which stops
        audio mid-stream; "stop" tears the session down entirely, which is
        strictly worse. The knob to actually keep music playing is
        androidSettings below, because the suspend is Android's REQUEST --
        the host only obeys it.
      '';
    };

    androidSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        # Android sleeps its display 60s after the last window closes (measured:
        # `settings get system screen_off_timeout` returned 60000), then sends
        # TRANSACTION_suspend over binder and the host freezes the container --
        # which is why background audio dies about a minute after you close the
        # window, and why it resumes the instant you reopen it: a freeze
        # preserves state, it does not kill the app. Never sleeping means never
        # asking, at the cost of a container that never freezes.
        "system screen_off_timeout" = "2147483647";
      };
      example = lib.literalExpression ''{ "global stay_on_while_plugged_in" = "7"; }'';
      description = ''
        Android `settings` to enforce inside the container, keyed by
        "<namespace> <key>" (namespace being system, secure or global).

        Applied by a unit rather than an activation script because these live
        in Android's settings provider, not in a file on the host: they need
        the container actually running to write. Idempotent -- each is read
        back first and only written when it differs.
      '';
    };
  };

  config = lib.mkMerge [

    (lib.mkIf cfg.enable {
      virtualisation.waydroid.enable = true;

      # Always use the nftables build. Plain `waydroid` wraps `waydroid-net.sh` with `iptables`;
      # NixOS firewalls/stack are effectively nft-based (`USE_NFTABLES=1` in nixpkgs), otherwise
      # `RuntimeError … waydroid-net.sh start` is common (`networking.nftables.enable` is often unset).
      virtualisation.waydroid.package = pkgs.waydroid-nftables;

      environment.systemPackages = [ pkgs.wl-clipboard ];
    })

    /*
      android-tools travels with autoAdb, not with waydroid generally.

      Flipping auto_adb in waydroid.cfg makes the container expose adb, but
      nothing on the host could talk to it -- `adb` was not on PATH at all,
      so the setting was only half a feature. Sideloading an APK
      (`adb connect <waydroid-ip>:5555 && adb install foo.apk`) is the whole
      reason to enable it, since a MAINLINE image has no Play Store.
    */
    (lib.mkIf (cfg.enable && cfg.autoAdb) {
      environment.systemPackages = [ pkgs.android-tools ];
    })

    (lib.mkIf (cfg.enable && cfg.autoAdb) {

      system.activationScripts.waydroid-auto-adb = lib.mkAfter ''
        cfg=/var/lib/waydroid/waydroid.cfg
        if [ -r "$cfg" ] && grep -qxF 'auto_adb = False' "$cfg"; then
          ${lib.getExe pkgs.gnused} -i 's/^auto_adb = False/auto_adb = True/' "$cfg"
        fi
      '';
    })

    (lib.mkIf cfg.enable {
      # waydroid.cfg is state, not a store file, so this is the same
      # rewrite-in-place shape as auto_adb above. Only rewrites an existing
      # line: waydroid init always writes one, and appending into the right
      # ini section blind is not worth the fragility.
      system.activationScripts.waydroid-suspend-action = lib.mkAfter ''
        wcfg=/var/lib/waydroid/waydroid.cfg
        if [ -r "$wcfg" ] && grep -q '^suspend_action = ' "$wcfg" \
           && ! grep -qxF 'suspend_action = ${cfg.suspendAction}' "$wcfg"; then
          ${lib.getExe pkgs.gnused} -i 's/^suspend_action = .*/suspend_action = ${cfg.suspendAction}/' "$wcfg"
        fi
      '';
    })

    (lib.mkIf (cfg.enable && cfg.androidSettings != { }) {
      systemd.services.waydroid-android-settings = {
        description = "Apply declared Android settings inside Waydroid";
        after = [ "waydroid-container.service" ];
        wantedBy = [ "waydroid-container.service" ];
        path = [ config.virtualisation.waydroid.package ];
        # NOT RemainAfterExit: the timer below re-runs this, and systemd
        # treats `start` on an already-active oneshot as a no-op, so staying
        # active would mean it never retried.
        serviceConfig.Type = "oneshot";
        script = ''
          # READINESS, and why the obvious probe is wrong. `waydroid shell --
          # true` exits 0 while the container is STOPPED -- it merely prints
          # "WayDroid container is STOPPED" -- and exits 1 when the container
          # IS running but the caller is not root. Exit status carries no
          # information either way. Measured the hard way: an earlier version
          # of this unit polled on exit status, passed instantly at boot with
          # the container stopped, logged "settings put ... (was unset)" and
          # wrote precisely nothing, while reporting success.
          #
          # Ask Android instead. sys.boot_completed is 1 only once its settings
          # provider is actually up, which is the thing being written to.
          boot_completed() {
            [ "$(waydroid shell -- getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')" = "1" ]
          }

          ready=
          for _ in $(seq 1 15); do
            if boot_completed; then
              ready=1
              break
            fi
            sleep 2
          done
          if [ -z "$ready" ]; then
            # Expected at boot: the container only starts when an app is
            # launched. The timer retries, so this is not a failure.
            exit 0
          fi

          ${lib.concatStringsSep "\n" (
            lib.mapAttrsToList (k: v: ''
              # unquoted ${k}: it is "<namespace> <key>" and must split into two args
              cur=$(waydroid shell -- settings get ${k} 2>/dev/null | tr -d '\r\n')
              if [ "$cur" != ${lib.escapeShellArg v} ]; then
                waydroid shell -- settings put ${k} ${lib.escapeShellArg v}
                # Read back rather than trusting the write. `settings put` is
                # as quiet about a stopped container as everything else here.
                new=$(waydroid shell -- settings get ${k} 2>/dev/null | tr -d '\r\n')
                if [ "$new" = ${lib.escapeShellArg v} ]; then
                  echo "waydroid: ${k} = ${v} (was ''${cur:-unset})"
                else
                  echo "waydroid: FAILED to set ${k}, still ''${new:-unset}" >&2
                  exit 1
                fi
              fi
            '') cfg.androidSettings
          )}
        '';
      };

      # The container is STOPPED at boot -- it starts when an app is launched,
      # which may be hours later -- so a boot-time attempt alone is exactly the
      # window this setting is never applied in. Retry on a timer; each run
      # costs one getprop and exits immediately when Android is not up.
      systemd.timers.waydroid-android-settings = {
        description = "Retry Android settings until Waydroid is running";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "3min";
          OnUnitActiveSec = "10min";
          AccuracySec = "1min";
        };
      };
    })
  ];
}
