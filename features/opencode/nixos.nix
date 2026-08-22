{ config, lib, pkgs, ... }:

let
  cfg = config.my.opencode;
  # Its own packages, read here so the feature is self-contained.
  pkgSet = import ./packages.nix { inherit pkgs; };
in
{
  options.my.opencode = {
    enable = lib.mkEnableOption "opencode, pointed at a local model endpoint";

    baseURL = lib.mkOption {
      type = lib.types.str;
      default = "http://yulee:8002/v1/";
      description = ''
        OpenAI-compatible endpoint. Deliberately not shared with the
        claude-code feature's gemma wrapper: they happen to name the same host
        today, but they are independent consumers, not one value duplicated.
      '';
    };
  };

  # Accounts this feature applies to; defaults to the primary user.
  options.my.opencode.users = import ../../lib/user-scope.nix { inherit lib config; };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = pkgSet.system;
  };
}
