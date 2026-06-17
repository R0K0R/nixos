# Headscale tailnet via stock NixOS services.tailscale (kernel tailscale0).
# Pinned to nixos-24.05 tailscale: unstable 1.80+ rejects plain http:// login-server.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.headscaleClient;

  nixpkgs2405 = import (builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/nixos-24.05.tar.gz";
    sha256 = "0zydsqiaz8qi4zd63zsb2gij2p614cgkcaisnk11wjy3nmiq0x1s";
  }) {
    system = pkgs.stdenv.hostPlatform.system;
  };
in
{
  options.services.headscaleClient = {
    enable = lib.mkEnableOption "Headscale tailnet client (kernel Tailscale via services.tailscale)";

    loginServer = lib.mkOption {
      type = lib.types.str;
      default = "http://airbow.kro.kr:8080";
      description = "Headscale server_url (must match Headscale config).";
    };

    hostname = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Tailscale node name registered in Headscale.";
    };

    authKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "/etc/nix/secrets/tailscale-authkey";
      description = ''
        Headscale preauth key (hskey-auth-...). Read by root at boot.
        Install with: sudo install -Dm600 /dev/stdin /etc/nix/secrets/tailscale-authkey
        after: headscale preauthkeys create --user <id> --reusable --expiration 720h
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.tailscale = {
      enable = true;
      package = nixpkgs2405.tailscale;
      authKeyFile = cfg.authKeyFile;
      extraUpFlags = [
        "--login-server"
        cfg.loginServer
        "--hostname"
        cfg.hostname
        "--accept-routes"
        "--accept-dns=false"
      ];
    };

    # Retire userspace / ad-hoc units from older configs.
    systemd.services.tailscaled-headscale.enable = lib.mkForce false;
    systemd.services.tailscale-headscale-up.enable = lib.mkForce false;

    # Remote builder and user SSH should order after autoconnect when using auth key.
    systemd.services.nix-daemon.after = lib.mkAfter [ "tailscaled-autoconnect.service" ];
  };
}
