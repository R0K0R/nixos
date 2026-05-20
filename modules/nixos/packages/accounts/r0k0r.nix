{ pkgs, ... }:

with pkgs; [
  cursor-cli
  kitty
  fish
  git
  gh
  starship
  nixd
  nixfmt-rfc-style
  statix
  deadnix
  tree
  python3
  /* Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`). */
  basedpyright
  gcc
  gdb
  flutter
  dart
  tinymist
  typst
  (pkgs.texlive.combine {
    inherit (pkgs.texlive)
      scheme-medium
      graphics
      amsmath
      latexmk
      ;
  })
]
