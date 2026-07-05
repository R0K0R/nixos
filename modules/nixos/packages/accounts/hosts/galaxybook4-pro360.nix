{ pkgs, ... }:

with pkgs; [
  nixfmt

  # Explicit package list instead of scheme-medium: names every LaTeX
  # package actually used rather than relying on a broad bundled scheme.
  # dvisvgm and asymptote are both kept (both pull in qt5.qtbase as a
  # runtime dep via wrap-qt5-apps-hook) since both are actually used here.
  (texlive.combine {
    inherit (texlive)
      scheme-small
      graphics
      amsmath
      amsfonts
      latexmk
      geometry
      hyperref
      xcolor
      booktabs
      caption
      enumitem
      microtype
      csquotes
      pgf
      biblatex
      listings
      dvisvgm
      asymptote
      ;
  })
  biber
]
