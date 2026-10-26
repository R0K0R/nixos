{ config, lib, osConfig, ... }:


let
  cfg = config.my.ssh;
in
{
  options.my.ssh = {
    enable = lib.mkEnableOption "the SSH client config";

    identityFile = lib.mkOption {
      type = lib.types.str;
      default = "~/.ssh/id_ed25519";
      description = ''
        Default identity for the hosts below: the person's OWN key, whose
        public half is in registry/users/<name>.nix sshKeys. Not the builder
        key -- that one is root-only (features/nix/remote-builder).
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''{ yulee = { }; note10 = { Port = 8022; }; }'';
      description = ''
        Per-host ssh_config blocks, keyed by Host pattern. `IdentityFile`
        defaults to identityFile and can be overridden per entry.

        An option rather than a constant because these name specific machines on
        one person's network -- a cloned host must not inherit them. They were
        hardcoded here until the grep gate caught it.
      '';
    };
  };

  config = lib.mkIf (cfg.enable) {
    # private keys, authorized_keys, known_hosts (config is home-manager's)
    my.persist.directories = [ ".ssh" ];

    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;

      settings =
        lib.mapAttrs (_: opts: { IdentityFile = cfg.identityFile; } // opts) cfg.hosts
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
  };
}
