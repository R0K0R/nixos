{ lib, pkgs, osConfig, ... }:
let
  # Colour the clean braille logo (../../logo.txt, the one brand asset) with a fire gradient at build
  # time -- the canonical logo stays plain; only fire.py's colours vary. `file-raw` prints the embedded
  # ANSI verbatim, so it's fire-coloured instead of inheriting the terminal's (blue) accent.
  fireLogo = pkgs.runCommand "bonfire-logo-fire.txt" { } ''
    ${pkgs.python3}/bin/python3 ${./fire.py} ${../../logo.txt} > $out
  '';
in
{
  config = lib.mkIf (osConfig.my.fastfetch.enable or false) {
    programs.fastfetch = {
      enable = true;
      settings = {
        logo = {
          type = "file-raw";
          source = "${fireLogo}";
          padding = { top = 1; left = 2; right = 4; };
        };
        display.separator = "  ";
        modules = [
          "title"
          "separator"
          "os"
          "host"
          "kernel"
          "uptime"
          "packages"
          "shell"
          "wm"
          "terminal"
          "cpu"
          "gpu"
          "memory"
          "disk"
          "break"
          "colors"
        ];
      };
    };
  };
}
