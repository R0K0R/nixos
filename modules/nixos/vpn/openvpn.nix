{ ... }:

{
  /*
    OpenVPN: keep your *.ovpn (and optional auth-user-pass file) OUT of git.
    With /etc/nixos symlinked to this flake, store them under gitignored secrets/, e.g.:
      sudo install -Dm600 /path/to/your/export.ovpn /etc/nixos/secrets/openvpn/profile.ovpn
    If auth-user-pass is separate, chmod 600 that file too and reference it inside the .ovpn.
    Never use builtins.readFile on secrets — copies into world-readable store.
    Start/stop: `sudo systemctl start openvpn-home` / `sudo systemctl stop openvpn-home`
    Default off — Headscale reaches Yulee; OpenVPN hijacked routes/DNS and slowed SSH store copies.
  */
  services.openvpn.servers.home = {
    config = ''
      config /etc/nixos/secrets/openvpn/profile.ovpn
    '';
    autoStart = false;
    updateResolvConf = true;
  };
}
