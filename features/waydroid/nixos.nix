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

    tablet = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Present the container as a TABLET, by forcing
        `ro.build.characteristics=tablet` into /var/lib/waydroid/waydroid_base.prop.

        The reason is KakaoTalk (and other Kakao apps): one account may be
        signed in on a phone AND a tablet/PC at once, but two *phones* conflict.
        Waydroid identifies as a phone by default, so logging in there fights
        the real phone. As a tablet it registers as the secondary device and
        the two coexist.

        A `ro.` build prop, so it lives in waydroid_base.prop (applied at
        session start), not a runtime `persist.` prop. Takes effect after
        `waydroid session stop` + start (or a reboot); re-log KakaoTalk once so
        it re-registers as the tablet.
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

      # wl-clipboard: host<->container copy/paste. waydroid-helper: the GTK
      # tool that installs the extensions a MAINLINE image lacks -- ARM
      # translation (libndk/libhoudini, REQUIRED to run ARM-only apps like
      # KakaoTalk on this x86_64 host) and optional GApps. Runtime, one-time:
      # the .img files it fetches are not something a rebuild can place.
      environment.systemPackages = [
        pkgs.wl-clipboard
        pkgs.waydroid-helper
      ];
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

    /*
      Force the tablet build characteristic into waydroid_base.prop. Idempotent:
      drop any existing ro.build.characteristics line, then append the tablet
      one -- so toggling the option off (to `default`) is a matching edit, not
      a stale leftover. Only touches an initialised container (the prop file
      exists after `waydroid init`); a session restart applies it.
    */
    (lib.mkIf (cfg.enable && cfg.tablet) {
      system.activationScripts.waydroid-tablet = lib.mkAfter ''
        prop=/var/lib/waydroid/waydroid_base.prop
        if [ -w "$prop" ]; then
          ${lib.getExe pkgs.gnused} -i '/^ro\.build\.characteristics=/d' "$prop"
          printf 'ro.build.characteristics=tablet\n' >> "$prop"
        fi
      '';
    })
  ];
}
