{ pkgs }:
{
  user = with pkgs; [
    # Explicit package list instead of scheme-medium: names every LaTeX
    # package actually used rather than relying on a broad bundled scheme.
    # dvisvgm and asymptote are both kept (both pull in qt5.qtbase as a
    # runtime dep via wrap-qt5-apps-hook) since both are actually used here.
    #
    # texliveSmall.withPackages, not the deprecated texlive.combine (removed in
    # nixpkgs 27.05). texliveSmall is scheme-small, so the set is unchanged;
    # the derivation is new (2026-10-08) and rebuilds once.
    (texliveSmall.withPackages (ps: with ps; [
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
    ]))
    biber
  ];
}
