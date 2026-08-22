{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  services.tailscale.enable = true;

  system.stateVersion = "26.05";

  # Kernel choice stays in the host file: it is a property of this machine's
  # hardware, not of any feature.
  boot.kernelPackages = pkgs.linuxPackages_7_1;

  my = {
    /*
      This machine builds nothing.

      `enable = false` makes flake.nix hand it plain upstream nixpkgs, so the
      entire package set substitutes from cache.nixos.org and the only things
      compiled here are the few hundred config-generated derivations every NixOS
      system produces (system-path, etc, units) -- symlink and text assembly, no
      compilers.

      Literal, and it must stay one: flake.nix raw-imports this file to choose
      the nixpkgs input BEFORE the module system exists, so mkIf/mkMerge here
      cannot be resolved. It throws rather than guessing, and an assertion in
      tuning/nixos.nix cross-checks what flake.nix read against what the module
      system evaluated.

      Do NOT reach for `nixpkgs.pkgs = import inputs.nixpkgs-upstream { ... }`
      instead. It cannot work in this config: the nixpkgs module asserts
      `nixpkgs.pkgs is defined -> nixpkgs.config == {}`, and features/nix-settings
      sets allowUnfree while features/emacs sets problems.handlers. It also makes
      nixpkgs.overlays silently ignored. And `march = null` on its own does not
      help either -- the fork patches cc-wrapper's setup-hook.sh, whose bytes are
      a build input, so stdenv's hash moves and everything rebuilds regardless of
      the tuning switches.
    */
    tuning.enable = false;

    /*
      The person who uses this machine. Declaring an account creates it, and the
      primary is what every feature's `users` option defaults to -- so benjamin
      gets the accounts's packages and the home-manager side of every feature
      enabled below, with no feature naming him anywhere.
    */
    users.benjamin = {
      primary = true;
      description = "Benjamin S.H. Lee";
    };

    upower.enable = true;
    fonts.enable = true;
    keyd.enable = true;
    pipewire.enable = true;
    libinput.enable = true;
    swapfile.enable = true;
    discovery.enable = true;
    locale.enable = true;
    firefox.enable = true;
    fcitx.enable = true;
    openvpn.enable = true;
    waydroid.enable = true;
    session-env.enable = true;
    fish.enable = true;
    kitty.enable = true;
    starship.enable = true;
    cursor-theme.enable = true;
    ssh.enable = true;
    opencode.enable = true;
    nix-settings.enable = true;
    emacs.enable = true;

    # Package sets, each owning its own list (features/<name>/packages.nix).
    base.enable = true;
    eza.enable = true;
    dev-toolchain.enable = true;
    latex.enable = true;
    media.enable = true;
    desktop-apps.enable = true;
    diagnostics.enable = true;
    qt-dev.enable = true;

    claude-code = {
      enable = true;
      shareWithRoot = true;
      gemma.enable = true;
    };

    claude-desktop = {
      enable = true;
      cowork.enable = true;
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [

    ];

    power.enable = true;
    flatpak.enable = true;
    easyeffects.enable = true;

    boot.enable = true;

    emacs.machineLocalElisp = ''
      ;;; -*- lexical-binding: t; -*-
      ;;; Loaded by Doom `config.el` from ~/.config/home-manager/doom-machine-local.el

      (defun my/machine-local-reset-fonts-h ()
        (setq doom-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 16 :weight 'semi-light)
              doom-variable-pitch-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 16))
        (when (fboundp 'doom-init-fonts-h)
          (doom-init-fonts-h 'reload)))

      (add-hook 'emacs-startup-hook #'my/machine-local-reset-fonts-h)
    '';

    greetd.enable = true;
    qt-theming.enable = true;
    session-services.enable = true;

    desktop = {
      compositor = "hyprland";
      primaryOutput = "eDP-1";
      primaryOutputScale = "1";
    };

    dms = {
      enable = true;
      greeter.enable = true;
    };

    network = {
      enable = true;
      kdeconnect.enable = true;
    };
  };

  networking.hostName = "dell-latitude";

  /*
    No nixpkgs.buildPlatform / hostPlatform here. hardware-configuration.nix
    already sets hostPlatform at mkDefault, and on an untuned host the
    build != host split must NOT exist -- that split is precisely what
    tuning/overlays/upstream-tools.nix keys off to tell a build tool from
    something that runs at runtime. The platform is owned by my.tuning.march and
    by nothing else.
  */
}
