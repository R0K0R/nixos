{ pkgs, lib, inputs, ... }:

let
  flamencoSrc = pkgs.fetchzip {
    url = "https://projects.blender.org/studio/flamenco/archive/v3.9.2.tar.gz";
    hash = "sha256-xc5t5ThfnOvspieZoDyFX8KzZA3MSf80RQZygXrboFE=";
  };

  # BAT 2.1.0 (bundled in Flamenco 3.9.2) requires cattrs which was omitted from
  # the shipped wheels/. Build one from nixpkgs and inject it.
  cattrsWheel = pkgs.runCommand "cattrs-wheel-${pkgs.python3Packages.cattrs.version}" {
    nativeBuildInputs = [ pkgs.zip ];
  } ''
    mkdir -p dist/cattrs
    cp -r ${pkgs.python3Packages.cattrs}/${pkgs.python3.sitePackages}/cattrs/. dist/cattrs/
    mkdir -p $out
    cd dist && zip -r $out/cattrs-${pkgs.python3Packages.cattrs.version}-py3-none-any.whl cattrs/
  '';

  flamencoAddon = pkgs.runCommand "flamenco-addon-${flamencoSrc.name}" {} ''
    cp -r ${flamencoSrc}/addon/flamenco $out
    chmod -R u+w $out/wheels
    cp ${cattrsWheel}/*.whl $out/wheels/
  '';
in
{
  # Flamenco Blender addon — installed declaratively from pinned source archive.
  # Blender picks up addons dropped in ~/.config/blender/<major.minor>/scripts/addons/.
  home-manager.users.r0k0r.xdg.configFile."blender/${lib.versions.majorMinor pkgs.blender.version}/scripts/addons/flamenco" = {
    source = flamencoAddon;
    recursive = true;
  };

  home-manager.users.r0k0r.xdg.configFile."easyeffects/output" = {
    source = "${inputs.easyeffects-presets}/output";
    recursive = true;
  };

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
