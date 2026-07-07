{ ... }:

{
  # HTTP binary cache serving victus's own store, for hosts (galaxybook4-pro360)
  # that want to substitute from here. ssh-ng:// (used for --builders build
  # delegation) is a single Nix-daemon-worker-protocol channel -- efficient for
  # building, but substitutability queries over it are comparatively
  # serialized. HTTP is what Nix's substituter logic is most optimized for:
  # real parallel .narinfo requests, governed by --option http-connections.
  #
  # bindAddress is Tailscale-only and load-bearing: networking.firewall.enable
  # is false on this host, so there is no firewall layer to fall back on --
  # nix-serve binding to 0.0.0.0 would expose the store to anything that can
  # otherwise reach this machine, not just the tailnet.
  services.nix-serve = {
    enable = true;
    secretKeyFile = "/etc/nix/signing-key.pem";
    bindAddress = "100.64.0.2";
    port = 5000;
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  nix.settings.substituters = [
    "https://cache.nixos.org"
    "https://cuda-maintainers.cachix.org"
  ];
  nix.settings.trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
  ];
  nix.settings.secret-key-files = [ "/etc/nix/signing-key.pem" ];
  nix.settings.trusted-users = [ "r0k0r" ];
}
