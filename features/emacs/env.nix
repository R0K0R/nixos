/* Shared custom Emacs build; used by doom-config.nix. */
{ pkgs, inputs }:

let
  /*
    Unstable `emacs-pgtk` + xwidgets, against whatever WebKit nixpkgs ships.

    This used to pin webkitgtk from nixos-22.11 (2.38), because Emacs's
    configure once demanded `webkit2gtk-4.1 < 2.41.92'.  Emacs 31 asks only
    for `>= 2.12' -- the upper bound is gone from configure.ac -- so the pin
    now buys a 2022 engine and nothing else.  It cost: the preview stuttered
    on documents Firefox rendered smoothly, and tinymist's partial rendering
    drew the last page over the first, neither of which reproduces on a
    current WebKit.
  */
  emacsPgtkBase = (
    pkgs.emacs-pgtk.override {
      withNativeCompilation = true;
      withTreeSitter = true;
      withSystemd = true;
      withXwidgets = true;
    }
  );

  # nix-doom-emacs-unstraightened builds every Doom package (vterm included)
  # via `emacsPackagesFor emacsRolling`, matched to this exact Emacs build.
  emacsRolling = emacsPgtkBase;

  /*
    Terminal-only Emacs for headless hosts (victus-15 has no display manager or
    compositor -- its nvidia driver is there for CUDA). emacsPgtkBase would
    still *run* under `-nw`, but it drags GTK, WebKit 2.38 and xwidgets into
    the closure of a machine that can never display them, and that machine also
    builds. Native compilation and tree-sitter are kept: both are useful in a
    terminal, and TREESIT_GRAMMAR_DIR (doom-config.nix) feeds the same
    Nix-provided grammars either way.
  */
  emacsNox = (
    pkgs.emacs-nox.override {
      withNativeCompilation = true;
      withTreeSitter = true;
    }
  );
in
{
  inherit
    emacsPgtkBase
    emacsRolling
    emacsNox
    ;
}
