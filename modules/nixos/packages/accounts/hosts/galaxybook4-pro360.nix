{ pkgs, ... }:

with pkgs; [
  nixfmt-rfc-style

  (texlive.combine {
    inherit (texlive)
      scheme-medium
      graphics
      amsmath
      latexmk
      ;
  })
]
