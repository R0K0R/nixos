{ ... }:

{
  /*
    OpenVPN: keep your *.ovpn (and optional auth-user-pass file) OUT of git.
    With /etc/nixos symlinked to this flake, store them under gitignored secrets/, e.g.:
      sudo install -Dm600 /path/to/your/export.ovpn /etc/nixos/secrets/openvpn/profile.ovpn
    If auth-user-pass is separate, chmod 600 that file too and reference it inside the .ovpn.
    Never use builtins.readFile on secrets — copies into world-readable store.
    Start/stop: `sudo systemctl start openvpn-home` / `sudo systemctl stop openvpn-home`

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
      config /etc/nixos/secrets/openvpn/profile.ovpn
      pull-filter ignore "redirect-gateway"
      pull-filter ignore "dhcp-option DNS"
      pull-filter ignore "dhcp-option DOMAIN"
      pull-filter ignore "block-outside-dns"
    '';
    autoStart = false;
    updateResolvConf = false;
  };
}
