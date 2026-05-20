# Waydroid: Android in LXC/Wayland. Uses NixOS’s built‑in module (nixpkgs)
# (`virtualisation.waydroid` → pulls `virtualisation.lxc`, binder kernel config checks, systemd unit).

{ pkgs, lib, config, ... }:

let
  cfg = config.custom.waydroid;
in
{

  options.custom.waydroid = {

    enable = lib.mkEnableOption "Waydroid (Android compatibility layer)" // {
      default = false;
    };

    /* When enableAutoAdbConfigure is true, switches `auto_adb = False` → `True` in /var/lib/waydroid/waydroid.cfg on
       `nixos-rebuild` if the line is exactly `auto_adb = False`. This is the documented knob
       for painless host adb (Flutter: `flutter run -d …`). Turn off if you manage cfg yourself. */
    enableAutoAdbConfigure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Align Waydroid with host ADB tooling by enabling `auto_adb` in waydroid.cfg.
        With `ro.adb.secure=1` you may still need Developer options → USB debugging and one RSA approval in the Waydroid UI the first time.
      '';
    };
  };

  config = lib.mkMerge [

    (lib.mkIf cfg.enable {
      virtualisation.waydroid.enable = true;

      # Always use the nftables build. Plain `waydroid` wraps `waydroid-net.sh` with `iptables`;
      # NixOS firewalls/stack are effectively nft‑based (`USE_NFTABLES=1` in nixpkgs), otherwise
      # `RuntimeError … waydroid-net.sh start` is common (`networking.nftables.enable` is often unset).
      virtualisation.waydroid.package = pkgs.waydroid-nftables;

      environment.systemPackages = [ pkgs.wl-clipboard ];
    })

    (lib.mkIf (cfg.enable && cfg.enableAutoAdbConfigure) {

      system.activationScripts.waydroid-auto-adb = lib.mkAfter ''
        cfg=/var/lib/waydroid/waydroid.cfg
        if [ -r "$cfg" ] && grep -qxF 'auto_adb = False' "$cfg"; then
          ${lib.getExe pkgs.gnused} -i 's/^auto_adb = False/auto_adb = True/' "$cfg"
        fi
      '';
    })
  ];

}
