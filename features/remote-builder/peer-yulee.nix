/*
  Yulee build server (Ryzen 9900X). Reachable at Host `yulee` via Tailscale MagicDNS.
*/
{ config, lib, ... }:

let
  cfg = config.my.remote-builder.client;

  # Same reasoning as peer-victus-15.nix: the peer definition owns the SSH
  # user, so this block cannot drift from the nix.buildMachines entry.
  sshUser = cfg.peers.yulee.sshUser or config.my.internal.primaryUser;
  address = cfg.peers.yulee.address or "yulee";
in
# Gated on this peer being DECLARED, not merely on the client being enabled.
# Both peer files used to apply to every client, so dell-latitude -- which
# declares only victus-15 -- still got a `Host yulee` block naming a host it
# never contacts, at a bare name that does not resolve in its tailnet, as the
# wrong user.
#
# Declared, not enabled: a PARKED peer keeps its ssh block on purpose. Parking
# removes it from /etc/nix/machines, and the wrapper that names it is how you
# check whether the machine is back -- which needs the ssh config to still
# exist. See wrappers.enable.
lib.mkIf (cfg.enable && cfg.peers ? yulee) {
  programs.ssh = {
    knownHosts.yulee = {
      hostNames = lib.unique [
        "yulee"
        address
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2O6gqRdfKcKJQU/KLBGSnsf1VKj67IfHqzAEyWn014";
    };

    extraConfig = ''
      Host yulee
        HostName ${address}
        User ${sshUser}
        IdentityFile ${cfg.sshKey}
        ControlMaster auto
        ControlPath /run/nix-yulee-ssh-%r@%h:%p
        ControlPersist yes
        StrictHostKeyChecking yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
