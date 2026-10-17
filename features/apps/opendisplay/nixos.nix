{ config, lib, pkgs, ... }:

let
  cfg = config.my.opendisplay;
in
{
  options.my.opendisplay = {
    enable = lib.mkEnableOption ''
      opendisplay-linux: use an iPhone/iPad as an extra Wayland display. The
      Linux sender (PipeWire + portal capture -> H.264 -> the iOS receiver)
      over Wi-Fi or over a USB cable
    '';

    # Accounts this feature applies to; defaults to the primary user.
    users = import ../../../lib/user-scope.nix { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    /*
      The USB transport is usbmuxd, the iOS-device multiplexing daemon: a system
      service with udev rules, which no home can provide. Wi-Fi discovery is
      Avahi, which my.discovery already turns on; capture needs PipeWire and the
      compositor's screencast portal (xdg-desktop-portal-hyprland on Hyprland),
      both of which the session features provide. Hardware H.264 (h264_vaapi)
      additionally needs the GPU's VA-API driver -- a hardware fact, so it
      belongs in the host file (hardware.graphics.extraPackages), not here.
    */
    services.usbmuxd.enable = true;

    my.packages.perUser = lib.genAttrs cfg.users (_: [ (pkgs.callPackage ./package.nix { }) ]);
  };
}
