{ config, lib, ... }:

let
  cfg = config.my.libinput;
in
{
  options.my.libinput.enable = lib.mkEnableOption ''
    libinput touchpad support. Enabled by default under most desktopManagers, but
    this config runs a bare compositor under greetd with no desktopManager, so it
    has to be asked for
  '';

  config = lib.mkIf cfg.enable {
    services.libinput.enable = true;
  };
}
