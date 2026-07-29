{
  config,
  pkgs,
  inputs,
  lib,
  ...
}:

let
  emacsEnv = import ./env.nix { inherit pkgs inputs; };
  inherit (emacsEnv) vtermInstallScript;
in
{
  home.activation.syncDoomEmacsFramework = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    set -euo pipefail
    EMACSD="${config.home.homeDirectory}/.emacs.d"
    SRC="${inputs.doom-emacs}"
    mkdir -p "$EMACSD"
    # --no-{owner,group,perms}: ignore store UID and read-only modes; apply normal Unix modes + chmod below.
    ${lib.getExe pkgs.rsync} -a --delete --exclude '.local/' \
      --no-owner --no-group --no-perms \
      "$SRC/" "$EMACSD/"
    if [[ -d "$EMACSD/bin" ]]; then
      chmod -R u+rwx "$EMACSD/bin"
    fi
    find "$EMACSD" -mindepth 1 -maxdepth 1 ! -name '.local' ! -name 'bin' -exec chmod -R u+rwX {} +
  '';

  /*
    After Doom’s straight checkout exists: install the store-built module (libs + Emacs match).

    Straight’s native-comp/tree layout resolves `locate-library' for vterm.el to
    ~/.emacs.d/.local/straight/build-<ver>/vterm/ (symlink farm), while `emacs-libvterm' lives under
    repos/. `vterm.el' picks the build-* path for `require'/`vterm-module-compile', so the .so must
    exist beside that vterm.el, not only under repos/emacs-libvterm.
  */
  home.activation.installNixEmacsVtermIntoStraight =
    lib.hm.dag.entryAfter [ "syncDoomEmacsFramework" ]
      ''
        ${vtermInstallScript} "${config.home.homeDirectory}/.emacs.d"
      '';
}
