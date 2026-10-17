/*
  Victus-15 build server (Ryzen 5 5600H). Reachable at Host `victus-15` via Tailscale MagicDNS.
*/
{ config, lib, ... }:

lib.mkIf config.my.remote-builder.client.enable {
  programs.ssh = {
    knownHosts.victus-15 = {
      hostNames = [
        "victus-15"
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
        HostName victus-15
        User r0k0r
        StrictHostKeyChecking yes
        ConnectTimeout 10
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
