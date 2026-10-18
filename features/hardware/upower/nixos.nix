{ config, lib, ... }:

let
  cfg = config.my.upower;
in
{
  options.my.upower.enable =
    lib.mkEnableOption "upower, the D-Bus power/battery daemon read by DMS, niri bars and desktop UIs";

  config = lib.mkIf cfg.enable {
    services.upower.enable = true;
    my.state.system.optional.directories = [
      "/var/lib/upower" # battery charge/rate history for the device list; rebuilds slowly
    ];
  };
}
