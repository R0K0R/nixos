/*
  The SYSTEM half of LocalSend: its port. LocalSend discovers peers by
  multicast on UDP 53317 and receives files over TCP 53317; with the port
  closed this laptop can still find other devices (their replies come back
  through connection tracking) but never appears on theirs, and nothing can
  be sent to it. Every interface, Tailscale included, so sending to the
  tailnet address works where the Wi-Fi isolates clients.

  The app itself is the home's (a one-off package in the home repo's host
  file), as is its state (.local/share/org.localsend.localsend_app).
*/
{ config, lib, ... }:

let
  cfg = config.my.localsend;
in
{
  options.my.localsend = {
    enable = lib.mkEnableOption "LocalSend's port (53317, TCP and UDP) in the firewall";
    port = lib.mkOption {
      type = lib.types.port;
      default = 53317;
      description = "LocalSend's port, for both discovery (UDP) and transfers (TCP).";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    networking.firewall.allowedUDPPorts = [ cfg.port ];
  };
}
