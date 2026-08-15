{ config, lib, ... }:

let
  cfg = config.my.opencode;
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

  config = lib.mkIf cfg.enable { };
}
