{ inputs, ... }:

{
  # Doom owns Emacs startup; skipping HM avoids an emacsWithPackages wrapper injecting default.el.
  programs.emacs.enable = false;

  /* DOOMDIR → flake input `doom-private`. Host-specific Elisp: hosts/<host>/home.nix */
  xdg.configFile."doom".source = inputs.doom-private;
}
