/* Shared Emacs package pins for PGTK + WebKit; used by packages.nix and activation.nix. */
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

  /*
    `pkgs.libvterm` is not the Neovim libvterm API emacs-libvterm expects. nixpkgs’ `emacsPackagesFor … .vterm`
    builds against `libvterm-neovim` with the same Emacs we run; we copy `vterm-module.so` into Straight’s
    emacs-libvterm checkout on home activation (see `installNixEmacsVtermIntoStraight`).
  */
  emacsVtermModulePkg = (pkgs.emacsPackagesFor emacsPgtkBase).vterm;

  emacsRolling = emacsPgtkBase;

  /*
    Shared by activation.nix and the doom-sync service. `doom sync` rebuilds
    Straight's build-<ver>/ trees, which discards the vterm-module.so placed
    there on activation -- so the sync has to re-run this afterwards, and both
    call sites need the same logic. Takes ~/.emacs.d as $1.
  */
  vtermInstallScript = pkgs.writeShellScript "install-nix-vterm-into-straight" ''
    set -uo pipefail
    shopt -s nullglob
    emacsd="''${1:?usage: $0 <emacs.d>}"
    vf=( ${emacsVtermModulePkg}/share/emacs/site-lisp/elpa/vterm-*/vterm-module.so )
    if [[ ''${#vf[@]} -eq 0 ]]; then
      echo "no vterm-module.so under ${emacsVtermModulePkg}" >&2
      exit 0
    fi
    so="''${vf[0]}"
    straight="$emacsd/.local/straight"
    repo="$straight/repos/emacs-libvterm"
    if [[ -d "$repo" ]]; then
      install -Dm444 "$so" "$repo/vterm-module.so"
    fi
    if [[ -d "$straight" ]]; then
      for d in "$straight"/build-*/vterm; do
        [[ -d "$d" ]] || continue
        install -Dm444 "$so" "$d/vterm-module.so"
      done
    fi
  '';
in
{
  inherit
    emacsPgtkBase
    emacsVtermModulePkg
    emacsRolling
    vtermInstallScript
    ;
}
