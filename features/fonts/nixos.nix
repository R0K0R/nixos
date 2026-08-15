{ config, lib, pkgs, ... }:

let
  cfg = config.my.fonts;
in
{
  options.my.fonts.enable =
    lib.mkEnableOption "the system font set: JetBrains Mono Nerd Font plus Noto CJK sans/serif";

  config = lib.mkIf cfg.enable {
    fonts.packages = [
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.noto-fonts-cjk-sans
      pkgs.noto-fonts-cjk-serif
    ];
  };
}
