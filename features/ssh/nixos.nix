{ config, lib, ... }:

let
  cfg = config.my.ssh;
in
{
  options.my.ssh = {
    enable = lib.mkEnableOption "the user's SSH client config (home half only -- see home.nix)";

    builderKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/nix/remote-builder/ssh_key";
      description = ''
        Default identity for the hosts below. Read from outside the store at
        connect time; the remote-builder feature is what installs it.
      '';
    };

    hosts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''{ yulee = { }; note10 = { Port = 8022; }; }'';
      description = ''
        Per-host ssh_config blocks, keyed by Host pattern. `IdentityFile`
        defaults to builderKeyFile and can be overridden per entry.

        An option rather than a constant because these name specific machines on
        one person's network -- a cloned host must not inherit them. They were
        hardcoded here until the grep gate caught it.
      '';
    };
  };

  # Home-only feature: the NixOS side exists to declare the switches that
  # features/ssh/home.nix gates on via osConfig.
  # Accounts this feature applies to; defaults to the primary user.
  options.my.ssh.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable { };
}
