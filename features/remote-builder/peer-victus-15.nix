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

    extraConfig = ''
      Host victus-15
        HostName victus-15
        User r0k0r
        IdentityFile /etc/nix/remote-builder/ssh_key
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
