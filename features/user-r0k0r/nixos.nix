{ config, lib, ... }:

let
  cfg = config.my.user-r0k0r;
in
{
  options.my.user-r0k0r = {
    enable = lib.mkEnableOption "the r0k0r user account and its home-manager identity";

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "wheel" "networkmanager" "video" "audio" ];
      description = "Groups beyond the account itself. `wheel` is what grants sudo.";
    };

    hashedPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/etc/nixos/secrets/hashed-password-r0k0r";
      description = ''
        Path to a hashed-password file, read at activation time from OUTSIDE
        the Nix store. Null leaves password management to `passwd`.

        Never use builtins.readFile for this -- that copies the hash into the
        world-readable store.
      '';
    };

    shell = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Login shell. Null keeps the NixOS default.";
    };

    mutableUsers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        False makes the declared users the only ones, and requires every account
        to carry a hashedPasswordFile -- otherwise it becomes unloginnable after
        the first switch.
      '';
    };

    stateVersion = lib.mkOption {
      type = lib.types.str;
      default = "26.05";
      description = "home-manager compatibility version (see HM modules/misc/version.nix).";
    };
  };

  config = lib.mkIf cfg.enable {
    users.mutableUsers = cfg.mutableUsers;

    users.users.r0k0r = {
      isNormalUser = true;
      inherit (cfg) extraGroups;
    }
    // lib.optionalAttrs (cfg.hashedPasswordFile != null) {
      inherit (cfg) hashedPasswordFile;
    }
    // lib.optionalAttrs (cfg.shell != null) {
      inherit (cfg) shell;
    };
  };
}
