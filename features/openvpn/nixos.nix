{ config, lib, ... }:

let
  cfg = config.my.openvpn;
in
{
  options.my.openvpn = {
    enable = lib.mkEnableOption ''
      an OpenVPN client profile, defined but not auto-started. Bring it up with
      `sudo systemctl start openvpn-home`
    '';

    profile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/nixos/secrets/openvpn/profile.ovpn";
      description = ''
        Path to the .ovpn profile, read at runtime from outside the store.

        Keep the profile and any auth-user-pass file OUT of git -- with
        /etc/nixos symlinked to this flake, put them under the gitignored
        secrets/ directory:
          sudo install -Dm600 /path/to/export.ovpn ${"/etc/nixos/secrets/openvpn/profile.ovpn"}
        Never use builtins.readFile on a secret: that copies it into the
        world-readable Nix store.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    /*
      Used as an UNDERLAY for tailscale when abroad: DERP relays (tor<->tok)
      are slower than routing through home. tailscaled advertises tun0's
      10.8.0.x as a candidate endpoint automatically, so once the tunnel is up,
      peers on the VPN subnet upgrade from relay to a direct WireGuard path
      THROUGH the tunnel -- MagicDNS names keep resolving to 100.64.x and just
      ride the faster path. No tailscale config needed.

      The server pushes redirect-gateway + DNS (the historical "hijacked
      routes/DNS, slowed SSH store copies" problem) -- pull-filter refuses
      both, so only the VPN subnet routes via tun0: general traffic stays on
      the local uplink and tailscale's MagicDNS resolv.conf is never touched.
    */
    services.openvpn.servers.home = {
      config = ''
        config ${cfg.profile}
        pull-filter ignore "redirect-gateway"
        pull-filter ignore "dhcp-option DNS"
        pull-filter ignore "dhcp-option DOMAIN"
        pull-filter ignore "block-outside-dns"
      '';
      autoStart = false;
      updateResolvConf = false;
    };
  };
}
