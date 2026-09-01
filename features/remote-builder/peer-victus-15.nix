/*
  Victus-15 build server (Ryzen 5 5600H). Reachable at Host `victus-15` via Tailscale MagicDNS.
*/
{ config, lib, ... }:

let
  cfg = config.my.remote-builder.client;

  /*
    The peer's own sshUser, not a literal. This block and nix.buildMachines
    describe the SAME connection, so a hardcoded name here silently disagreed
    with the buildMachines entry the moment a second client host appeared:
    dell-latitude reaches this builder as `benjamin`, galaxybook4-pro360 as
    `r0k0r`. The daemon used buildMachines (correct user, wrong-for-latitude
    ssh_config), while interactive `ssh victus-15` used this block -- so the
    two disagreed only for the human, which is the hard kind to notice.

    `or` because a host may enable the client without declaring this peer; the
    fallback repeats the peer submodule's own sshUser default.
  */
  sshUser = cfg.peers.victus-15.sshUser or config.my.internal.primaryUser;

  # Bare name on a client inside the peer's own tailnet; FQDN on one that sees
  # it as a shared node. See the `address` option for why this is per-client.
  address = cfg.peers.victus-15.address or "victus-15";
in
# Declared, not enabled -- see the same gate in peer-yulee.nix.
lib.mkIf (cfg.enable && cfg.peers ? victus-15) {
  programs.ssh = {
    knownHosts.victus-15 = {
      # Both, because ssh checks known_hosts against the resolved HostName --
      # listing only the alias makes StrictHostKeyChecking reject the FQDN.
      hostNames = lib.unique [
        "victus-15"
        address
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzOSdxCVOGM5cLeBc6pRC+0kmi2XCzx4UMfsAsDnR2Q";
    };

    extraConfig = ''
      Host victus-15
        HostName ${address}
        User ${sshUser}
        IdentityFile ${cfg.sshKey}
        ControlMaster auto
        ControlPath /run/nix-victus-15-ssh-%r@%h:%p
        ControlPersist yes
        StrictHostKeyChecking yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
