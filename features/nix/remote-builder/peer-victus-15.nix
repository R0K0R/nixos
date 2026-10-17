/*
  Victus-15 build server (Ryzen 5 5600H). Reachable at Host `victus-15` via Tailscale MagicDNS.
*/
{ config, lib, ... }:

let
  cfg = config.my.remote-builder.client;

  # The peer's own sshUser, not a literal: this block and nix.buildMachines
  # describe the SAME connection, so a hardcoded name here would disagree with
  # the entry for any client whose primary user is not r0k0r. `or` because a
  # host may enable the client without declaring this peer; the fallback
  # repeats the peer submodule's own default.
  sshUser = cfg.peers.victus-15.sshUser or config.my.internal.primaryUser;

  # Bare name on a client inside the peer's own tailnet; the FQDN on one that
  # sees it as a shared node. See the `address` option.
  address = cfg.peers.victus-15.address or "victus-15";
in
# Declared, not enabled: a PARKED peer keeps its ssh block on purpose (parking
# removes it from /etc/nix/machines, and the wrapper that names it is how you
# check whether the machine is back). But a client that never declared this
# peer gets no `Host victus-15` block naming a machine it never contacts.
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

    # The builder key and the /run control socket are ROOT's (the daemon's):
    # the key is root-only, since on a peer it is what is trusted, and a
    # person's ssh uses his own key (registry sshKeys) and cannot bind in /run.
    extraConfig = ''
      Match host victus-15 localuser root
        IdentityFile ${config.my.remote-builder.client.sshKey}
        ControlMaster auto
        ControlPath /run/nix-victus-15-ssh-%r@%h:%p
        ControlPersist yes
      Host victus-15
        HostName ${address}
        User ${sshUser}
        StrictHostKeyChecking yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
