/* Shared Emacs package pins for PGTK + WebKit; used by packages.nix and activation.nix. */
{ pkgs, inputs }:

let
  /*
    Pin from flake input `nixpkgs-emacs-webkit` — use `.legacyPackages` here, not `import … { config = pkgs.config }`,
    or NixOS’s nixpkgs options leak into 22.11 and blow up (`replaceStdenv` / stdenv mismatch).
  */
  pkgsWebkit = inputs.nixpkgs-emacs-webkit.legacyPackages.${pkgs.system};

  # Unstable `emacs-pgtk` (e.g. 30.x) + xwidgets, but linked against the older WebKit above.
  emacsPgtkBase = (
    pkgs.emacs-pgtk.override {
      webkitgtk_4_1 = pkgsWebkit.webkitgtk_4_1;
      withNativeCompilation = true;
      withTreeSitter = true;
      withSystemd = true;
      withXwidgets = true;
    }
  );

  /*
    `pkgs.libvterm` is not the Neovim libvterm API emacs-libvterm expects. nixpkgs’ `emacsPackagesFor … .vterm`
    builds against `libvterm-neovim` with the same Emacs we run; we copy `vterm-module.so` into Straight’s
    emacs-libvterm checkout on home activation (see `installNixEmacsVtermIntoStraight`).
  */
  emacsVtermModulePkg = (pkgs.emacsPackagesFor emacsPgtkBase).vterm;

  emacsRolling = emacsPgtkBase;
in
{
  inherit emacsPgtkBase emacsVtermModulePkg emacsRolling;
}
