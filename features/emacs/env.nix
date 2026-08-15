/* Shared custom Emacs build; used by doom-config.nix. */
{ pkgs, inputs }:

let
  /*
    Pin from flake input `nixpkgs-emacs-webkit` — use `.legacyPackages` here, not `import … { config = pkgs.config }`,
    or NixOS’s nixpkgs options leak into 22.11 and blow up (`replaceStdenv` / stdenv mismatch).
  */
  pkgsWebkit = inputs.feat-emacs.webkitPkgs.${pkgs.stdenv.hostPlatform.system};

  # Unstable `emacs-pgtk` (e.g. 30.x) + xwidgets, but linked against the older WebKit above.
  emacsPgtkBase = (
    pkgs.emacs-pgtk.override {
      webkitgtk_4_1 = pkgsWebkit.webkitgtk_4_1;
      glib-networking = pkgsWebkit.glib-networking;
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
