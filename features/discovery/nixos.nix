{ config, lib, ... }:

let
  cfg = config.my.discovery;
in
{
  options.my.discovery.enable =
    lib.mkEnableOption "local-network and peripheral discovery: Bluetooth plus Avahi/mDNS (nssmdns4)";

  config = lib.mkIf cfg.enable {
    hardware.bluetooth.enable = true;

    # bluez ships this user unit but leaves it disabled. It reports the local MPRIS
    # players' play/pause state to a connected headset (AVRCP target). Without it the
    # Galaxy Buds only track their own presses, so after pausing from the laptop
    # their next click sent Pause again and resuming took two clicks.
    systemd.user.services.mpris-proxy.wantedBy = [ "default.target" ];

    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
  };
}
