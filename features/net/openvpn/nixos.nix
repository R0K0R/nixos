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

    profileSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "../../age/openvpn-profile.age";
      description = ''
        agenix file holding the .ovpn profile. Decrypts to the path `profile`
        defaults to, so setting this is normally all a host needs.
      '';
    };

    profile = lib.mkOption {
      type = lib.types.path;
      default = "/run/agenix/openvpn-profile";
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
      The profile carries inline credentials, so it is an agenix secret rather
      than an untracked file under /etc/nixos/secrets that had to be installed
      by hand on every machine.

      Declared here rather than left to the host: cfg.profile defaults to the
      /run/agenix path, so the secret and the consumer cannot drift.
    */
    age.secrets = lib.mkIf (cfg.profileSecret != null) {
      openvpn-profile = {
        file = cfg.profileSecret;
        mode = "0400";
        owner = "root";
        group = "root";
      };
    };

    /*
      Same silent-failure class features/emacs guards against: a declared
      age.secrets entry on a host without agenix evaluates, builds and
      switches, leaving openvpn pointing at a file that was never decrypted.
      The tunnel then fails at connect time rather than at build time.
    */
    assertions = [
      {
        assertion = cfg.profileSecret == null || config.my.agenix.enable;
        message = "my.openvpn.profileSecret requires my.agenix.enable";
      }
    ];

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
