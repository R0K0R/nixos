{ config, lib, pkgs, osConfig, ... }:


{
  options.my.eza = {
    enable = lib.mkEnableOption "eza, the ls replacement";
  };

  config = lib.mkIf (config.my.eza.enable) {
    home.packages = [ pkgs.eza ];
  };
}
