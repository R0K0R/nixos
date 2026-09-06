{ config, lib, pkgs, ... }:

let
  cfg = config.my.fonts;
in
{
  options.my.fonts.enable =
    lib.mkEnableOption "the system font set: Departure Mono (primary), JetBrains Mono Nerd Font, Noto CJK sans/serif";

  config = lib.mkIf cfg.enable {
    fonts.packages = [
      # The nerd-fonts build, not plain departure-mono: kitty and the waybar
      # modules render nerd icon glyphs from their text font, so the primary
      # face has to carry them the way JetBrainsMono Nerd Font did.
      pkgs.nerd-fonts.departure-mono
      pkgs.nerd-fonts.jetbrains-mono
      pkgs.noto-fonts-cjk-sans
      pkgs.noto-fonts-cjk-serif
    ];

    /*
      Departure Mono as the system-wide monospace, by fontconfig default
      rather than per-app hunting: anything that asks for "monospace" gets it.
      JetBrains stays as the fallback face (fuller Unicode coverage than a
      pixel font), and Noto CJK catches Korean. The explicit font names in
      features/kitty and the host's Emacs elisp are updated to match --
      fontconfig defaults do not reach apps that name a family outright.
    */
    fonts.fontconfig.defaultFonts.monospace = [
      "DepartureMono Nerd Font"
      "JetBrainsMono Nerd Font"
      "Noto Sans Mono CJK KR"
    ];
  };
}
