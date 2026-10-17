/*
  Yulee build server (Ryzen 9900X). Reachable at Host `yulee` via Tailscale MagicDNS.
*/
{ config, lib, ... }:

lib.mkIf config.my.remote-builder.client.enable {
  programs.ssh = {
    knownHosts.yulee = {
      hostNames = [
        "yulee"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2O6gqRdfKcKJQU/KLBGSnsf1VKj67IfHqzAEyWn014";
    };

    # The builder key and the /run control socket are ROOT's (the daemon's):
    # the key is root-only, since on a peer it is what is trusted, and a
    # person's ssh uses his own key (registry sshKeys) and cannot bind in /run.
    extraConfig = ''
      Match host yulee localuser root
        IdentityFile ${config.my.remote-builder.client.sshKey}
        ControlMaster auto
        ControlPath /run/nix-yulee-ssh-%r@%h:%p
        ControlPersist yes
      Host yulee
        HostName yulee
        User r0k0r
        StrictHostKeyChecking yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
