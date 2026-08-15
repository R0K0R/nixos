{ config, lib, ... }:

let
  cfg = config.my.network;
in
{
  options.my.network = {
    enable = lib.mkEnableOption "NetworkManager (configure interactively with nmcli or nmtui)";

    kdeconnect.enable = lib.mkEnableOption ''
      the KDE Connect UDP port (1716) in the firewall. Separate from installing
      kdeconnect-kde itself, which is a package, not a firewall rule
    '';
  };

  config = lib.mkIf cfg.enable {
    networking.networkmanager.enable = true;

    networking.firewall.allowedUDPPorts = lib.mkIf cfg.kdeconnect.enable [ 1716 ];
  };
}
