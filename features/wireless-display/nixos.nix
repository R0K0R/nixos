{ config, lib, pkgs, ... }:

let
  cfg = config.my.wireless-display;

  # Read here rather than assembled centrally, same as every other feature;
  # tuning/runtime-cache/lookup.nix reads it independently for Tier 3.
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.wireless-display.enable = lib.mkEnableOption ''
    casting the screen to a wireless display -- Miracast TVs, monitors and
    dongles over Wi-Fi Direct, or Chromecast -- with GNOME Network Displays.
    Needs NetworkManager with a Wi-Fi card that offers a wifi-p2p device
    (nmcli device: p2p-dev-<iface>) and a screen-capture portal
  '';

  # Accounts this feature applies to; defaults to the primary user.
  options.my.wireless-display.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.networkmanager.enable;
        message = "my.wireless-display: Miracast runs its Wi-Fi Direct link through NetworkManager.";
      }
    ];

    my.packages.perUser = lib.genAttrs cfg.users (_: pkgSet.user);

    networking.firewall = {
      /*
        Miracast: the laptop becomes the Wi-Fi Direct group owner, gives the
        display an address over DHCP on the p2p-<iface>-N link, and serves the
        RTSP control channel the display connects back to. Each such link is a
        point-to-point connection to the one display you picked, so trust it
        rather than enumerating DHCP and RTP ports.
      */
      trustedInterfaces = [ "p2p-+" ];
      /*
        RTSP control (7236) and Miracast over an existing network, "MICE"
        (7250), for displays reached over the LAN instead of Wi-Fi Direct.
        Chromecast needs nothing inbound beyond the mDNS already open.
      */
      allowedTCPPorts = [ 7236 7250 ];
    };

    # Chromecast discovery is mDNS.
    services.avahi = {
      enable = lib.mkDefault true;
      nssmdns4 = lib.mkDefault true;
    };
  };
}
