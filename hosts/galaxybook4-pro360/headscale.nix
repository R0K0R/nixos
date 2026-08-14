# Headscale via services.tailscale (kernel tailscale0). Auth key for first boot / re-register:
#   sudo install -Dm600 /dev/stdin /etc/nix/secrets/tailscale-authkey <<'EOF'
#   hskey-auth-...
#   EOF
{
  services.headscaleClient = {
    enable = false;
    hostname = "galaxybook4-pro360";
    loginServer = "http://airbow.kro.kr:8080";
  };
}
