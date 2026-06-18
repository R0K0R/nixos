{ pkgs, ... }:

with pkgs; [
  nixfmt

  (texlive.combine {
    inherit (texlive)
      scheme-medium
      graphics
      amsmath
      latexmk
      ;
  })
]
