{ ... }:

{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."yulee" = {
      IdentityFile = "/etc/nix/remote-builder/ssh_key";
    };
    settings."victus-15" = {
      IdentityFile = "/etc/nix/remote-builder/ssh_key";
    };
    settings."note10" = {
      IdentityFile = "/etc/nix/remote-builder/ssh_key";
      Port = 8022;
    };
    settings."*" = {
      ForwardAgent = false;
      AddKeysToAgent = "no";
      Compression = false;
      ServerAliveInterval = 0;
      ServerAliveCountMax = 3;
      HashKnownHosts = false;
      UserKnownHostsFile = "~/.ssh/known_hosts";
      ControlMaster = "no";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "no";
    };
  };
}
