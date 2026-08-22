{ config, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.ssh.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "ssh"; };
in
let
  cfg = osConfig.my.ssh;
in
lib.mkIf (cfg.enable && inScope) {
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
