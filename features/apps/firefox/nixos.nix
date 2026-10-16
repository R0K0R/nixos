{ config, lib, pkgs, ... }:

let
  cfg = config.my.firefox;
in
{
  options.my.firefox = {
    enable = lib.mkEnableOption "Firefox";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.firefox-bin;
      defaultText = lib.literalExpression "pkgs.firefox-bin";
      description = ''
        Defaults to the Mozilla binary build rather than the source build: on a
        tuned host the source build is a multi-hour compile for no runtime gain
        this config cares about.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.firefox = {
      enable = true;
      inherit (cfg) package;
    };
  };
}
