{
  config,
  pkgs,
  inputs,
  ...
}:

let
  emacsEnv = import ./env.nix { inherit pkgs inputs; };
  inherit (emacsEnv) emacsRolling;
in
{
  home.packages =
    let
      doomcli = "${config.home.homeDirectory}/.emacs.d/bin/doom";
    in
    with pkgs;
    [
      emacsRolling
      imagemagick # PGTK Emacs cannot enable --with-imagemagick in nixpkgs; use CLI / scripts.

      # ~/.emacs.d/bin is easy to miss in PATH (fish/kitty must source hm-session-vars). This shadows nothing: same script.
      (writeShellScriptBin "doom" ''
        set -euo pipefail
        if ! [ -x "${doomcli}" ]; then
          echo "doom: expected executable at ${doomcli} (run home activation / nixos-rebuild first)." >&2
          exit 127
        fi
        exec "${doomcli}" "$@"
      '')

      git
      ripgrep
      fd
      findutils
      gnutar
      gzip
    ];

  home.sessionPath = [
    "${config.home.homeDirectory}/.emacs.d/bin"
  ];
}
