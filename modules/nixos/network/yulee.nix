/*
  Yulee build server (Ryzen 9900X). Reachable at Host `yulee` (100.64.0.1) over kernel Tailscale.
*/
{ ... }:

{
  networking.hosts = {
    "100.64.0.1" = [ "yulee" ];
  };

  programs.ssh = {
    knownHosts.yulee = {
      hostNames = [
        "yulee"
        "100.64.0.1"
      ];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM2O6gqRdfKcKJQU/KLBGSnsf1VKj67IfHqzAEyWn014";
    };

    extraConfig = ''
      Host yulee
        HostName 100.64.0.1
        User r0k0r
        IdentityFile /etc/nix/remote-builder/ssh_key
        ControlMaster auto
        ControlPath /run/nix-yulee-ssh-%r@%h:%p
        ControlPersist yes
        StrictHostKeyChecking yes
        ServerAliveInterval 30
        ServerAliveCountMax 3
    '';
  };
}
