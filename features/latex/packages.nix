{ pkgs }:
{
  user = with pkgs; [
    # Explicit package list instead of scheme-medium: names every LaTeX
    # package actually used rather than relying on a broad bundled scheme.
    # dvisvgm and asymptote are both kept (both pull in qt5.qtbase as a
    # runtime dep via wrap-qt5-apps-hook) since both are actually used here.
    #
    # TODO: texlive.combine is deprecated and removed in nixpkgs 27.05 --
    # port to texliveSmall.withPackages. The package set is explicit either
    # way, so it is a mechanical translation; it changes the texlive
    # derivation hash, so do it deliberately rather than mixed into another
    # change.
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
  ];
}
