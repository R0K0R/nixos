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
        Identity used for the remote-builder peers. Read from outside the store
        at connect time; the remote-builder feature is what installs it.
      '';
    };
  };

  # NixOS side declares options only. Everything this feature does lives in the
  # home half, which reads osConfig.my.ssh.
  config = lib.mkIf cfg.enable { };
}
