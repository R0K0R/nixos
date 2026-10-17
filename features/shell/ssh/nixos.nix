{ config, lib, ... }:

let
  cfg = config.my.ssh;
in
{
  options.my.ssh = {
    enable = lib.mkEnableOption "the user's SSH client config (home half only -- see home.nix)";

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

  # Home-only feature: the NixOS side exists to declare the switches that
  # features/ssh/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.ssh.users = import ../../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable { };
}
