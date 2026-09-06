{ config, lib, ... }:

let
  cfg = config.my.discovery;
in
{
  options.my.discovery.enable =
    lib.mkEnableOption "local-network and peripheral discovery: Bluetooth plus Avahi/mDNS (nssmdns4)";

  config = lib.mkIf cfg.enable {
    hardware.bluetooth.enable = true;

    # blueman's D-Bus mechanism + polkit rules, so blueman-applet (started as a
    # session service in features/network) can pair/connect without a root
    # prompt each time. The applet itself is the tray GUI; this is its backend.
    services.blueman.enable = true;

    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
  };
}
