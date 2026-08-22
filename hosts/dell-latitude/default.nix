{ inputs, lib, pkgs, ... }:

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
      This machine builds nothing. `enable = false` makes flake.nix hand it
      plain upstream nixpkgs, so the whole package set substitutes from
      cache.nixos.org.

      Literal, and it must stay one: flake.nix raw-imports this file to choose
      the nixpkgs input before the module system exists, so mkIf/mkMerge here
      cannot be resolved (it throws rather than guessing).

      This replaces an earlier `nixpkgs.pkgs = import inputs.nixpkgs-upstream`,
      which could not work: the nixpkgs module asserts nixpkgs.config == {}
      whenever nixpkgs.pkgs is set, and features/nix-settings sets allowUnfree
      while features/emacs sets problems.handlers. It also silently ignored
      nixpkgs.overlays. (That version additionally read `sytsem = ...`, which
      nixpkgs accepts without complaint because its top-level takes `...` -- the
      argument was simply dropped and `system` fell back to its default.)
    */
    tuning = {
      enable = false;
      march = null;
    };

    user-benjamin.enable = true;
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
    ssh = {
      enable = true;
    };
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

    boot = {
      enable = true;
    };

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
      # 2880x1800 internal panel.
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
    No nixpkgs.buildPlatform / hostPlatform here. They were declaring a
    build == host split with no gcc.arch, which is what nixosSystem already does
    from `system` -- and on an untuned host the split is exactly what must NOT
    exist, since it is the thing overlays/upstream-tools.nix keys off. The
    platform is owned by my.tuning.march (tuning/nixos.nix) and by nothing else.
  */

  /*
    Host-specific overlays only. Everything generic -- the pseudo-cross and
    build-load fixes, o3/LTO, upstream-tools, the i686 escape hatch -- moved to
    tuning/, behind the my.tuning.* switches above. What is left is about this
    machine's hardware and nothing else, which is why it cannot be shared.
  */
}
