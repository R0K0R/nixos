{ lib, osConfig, ... }:

let
  cfg = osConfig.my.ssh;
in
lib.mkIf cfg.enable {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."yulee" = {
      IdentityFile = cfg.builderKeyFile;
    };
    settings."victus-15" = {
      IdentityFile = cfg.builderKeyFile;
    };
    settings."note10" = {
      IdentityFile = cfg.builderKeyFile;
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
