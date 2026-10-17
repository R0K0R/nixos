{ config, lib, pkgs, ... }:
let
  # Colour the clean braille logo (the repo-root logo.txt, the one brand asset) with a fire gradient at build
  # time -- the canonical logo stays plain; only fire.py's colours vary. `file-raw` prints the embedded
  # ANSI verbatim, so it's fire-coloured instead of inheriting the terminal's (blue) accent.
  fireLogo = pkgs.runCommand "bonfire-logo-fire.txt" { } ''
    ${pkgs.python3}/bin/python3 ${./fire.py} ${../../../logo.txt} > $out
  '';
in
{
  # fastfetch with the bonfire logo. First visible piece of the bonfire rebrand; see REBRAND.md.
  options.my.fastfetch.enable = lib.mkEnableOption "fastfetch system info with the bonfire logo, as the fish greeting";

  config = lib.mkIf config.my.fastfetch.enable {
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

    # The fish greeting runs fastfetch, replacing fish's default text. A function, not
    # `set fish_greeting`: defining the function overrides the variable-printing default outright.
    # The system's fish home half only does `set fish_greeting` (empty), so this is the one thing
    # the two disagree on: mkForce is not needed because a function and a variable do not collide
    # -- the function wins at call time. `command -q` guards a host without fastfetch.
    programs.fish.functions.fish_greeting.body = ''
      command -q fastfetch; and fastfetch
    '';
  };
}
