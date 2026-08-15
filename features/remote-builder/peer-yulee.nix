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

    extraConfig = ''
      Host yulee
        HostName yulee
        User r0k0r
        IdentityFile /etc/nix/remote-builder/ssh_key
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
