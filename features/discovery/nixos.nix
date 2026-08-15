{ config, lib, ... }:

let
  cfg = config.my.discovery;
in
{
  options.my.discovery.enable =
    lib.mkEnableOption "local-network and peripheral discovery: Bluetooth plus Avahi/mDNS (nssmdns4)";

  config = lib.mkIf cfg.enable {
    hardware.bluetooth.enable = true;

    services.avahi = {
      enable = true;
      nssmdns4 = true;
    };
  };
}
