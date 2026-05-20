{ ... }:

{
  /*
    Victus DPI is low enough that Doom’s default font size reads too large; reset on startup.
    Galaxybook4-pro360 omits this file’s equivalent — high-DPI screen is fine without it.
  */
  home-manager.users.r0k0r.xdg.configFile."home-manager/doom-machine-local.el".text = ''
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
