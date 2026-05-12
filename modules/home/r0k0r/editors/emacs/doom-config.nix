{ inputs, ... }:

{
  # Doom owns Emacs startup; skipping HM avoids an emacsWithPackages wrapper injecting default.el.
  programs.emacs.enable = false;

  /*
    DOOMDIR → flake input `doom-private`.
    Machine-local Elisp (editable here in Nix): ~/.config/home-manager/doom-machine-local.el
  */
  xdg.configFile."doom".source = inputs.doom-private;

  xdg.configFile."home-manager/doom-machine-local.el".text = ''
    ;;; -*- lexical-binding: t; -*-
    ;;; Loaded by Doom `config.el` from ~/.config/home-manager/doom-machine-local.el

    (defun my/machine-local-reset-fonts-h ()
      (setq doom-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 13 :weight 'semi-light)
            doom-variable-pitch-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 13))
      (when (fboundp 'doom-init-fonts-h)
        (doom-init-fonts-h 'reload)))

    (add-hook 'emacs-startup-hook #'my/machine-local-reset-fonts-h)
  '';
}
