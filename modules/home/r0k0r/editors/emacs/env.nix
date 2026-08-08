/* Shared custom Emacs build; used by doom-config.nix. */
{ pkgs, inputs }:

let
  /*
    Pin from flake input `nixpkgs-emacs-webkit` — use `.legacyPackages` here, not `import … { config = pkgs.config }`,
    or NixOS’s nixpkgs options leak into 22.11 and blow up (`replaceStdenv` / stdenv mismatch).
  */
  pkgsWebkit = inputs.nixpkgs-emacs-webkit.legacyPackages.${pkgs.stdenv.hostPlatform.system};

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
in
{
  inherit
    emacsPgtkBase
    emacsRolling
    ;
}
