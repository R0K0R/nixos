{ lib, osConfig, ... }:

let
  cfg = osConfig.my.ssh;
in
lib.mkIf cfg.enable {
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;

    settings =
      lib.mapAttrs (_: opts: { IdentityFile = cfg.builderKeyFile; } // opts) cfg.hosts
      // {
        "*" = {
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
  };
}
