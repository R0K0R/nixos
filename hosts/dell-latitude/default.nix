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
    keyd.enable = false;
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
      # Interactive `ssh yulee`. IdentityFile defaults to
      # my.ssh.builderKeyFile, which remote-builder points at its own sshKey --
      # so the human and the nix-daemon reach the peer with the same
      # credential, as benjamin.
      hosts.yulee = { };
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

    hop.enable = true;

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
      Offload builds to yulee, as benjamin.

      Deliberately NOT a copy of galaxybook4-pro360's block, on three counts:

        - sshUser is left at its default, which is this host's primary user --
          benjamin, not r0k0r. That single fact is what the peer's ssh_config
          block now reads (peer-yulee.nix), instead of the literal it used to
          hardcode.

        - sshKeySecret stays null. There is no my.agenix.enable on this host,
          and the option's own docs make null the documented fallback: the key
          is hand-installed at /etc/nix/remote-builder/ssh_key, a DIFFERENT
          keypair from the one galaxybook decrypts out of
          age/remote-builder-ssh-key.age. Two client hosts, two credentials,
          two authorized_keys entries on the peer -- so revoking this laptop
          does not lock the other one out. Bootstrap is
          scripts/bootstrap-yulee-builder-benjamin.sh.

          UNLIKE victus-15, yulee is not a nixosConfigurations output of this
          flake -- there is no hosts/yulee. Its /etc/nix/nix.conf is hand-
          administered (see scripts/yulee-nix-access-fix.sh for the existing
          pattern). So granting benjamin trusted-user status there, and
          confirming a benjamin account even exists on that machine, is NOT
          something a rebuild here can do -- it happens only on yulee itself,
          by hand. The bootstrap script prints the exact steps and will not
          silently proceed without them.

        - `features` is left at its default (no gccarch-*). my.tuning.enable
          is false here, so nothing this host builds requests one, and
          nix.buildMachines.supportedFeatures now reads each peer's own
          declared `features` rather than assuming every peer can execute
          meteorlake code (features/remote-builder, upstream commit
          64f6696) -- so /etc/nix/machines advertises exactly what this
          peer supports and nothing this host doesn't need.

      max-jobs becomes 0 (features/remote-builder sets it whenever the client
      is enabled) -- this host then builds NOTHING locally, including the
      doom-intermediates IFD that runs during evaluation. If yulee is
      unreachable, park it: peers.yulee.enable = false. That is the only
      lever that works; --builders cannot reach the eval step. See the
      `enable` option's description for why.
    */
    remote-builder.client = {
      enable = true;
      wrappers.enable = true;
      flakePath = "/home/benjamin/flakes/nixos";
      # The ALIAS, not the FQDN -- peer-yulee.nix emits
      # `Host yulee / HostName <address>` into /etc/ssh/ssh_config, and the
      # daemon's ssh resolves this through it. Same for /etc/nix/machines.
      substituters = [ "ssh://benjamin@yulee" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
      ];
      peers.yulee = {
        maxJobs = 7;
        speedFactor = 10;
        /*
          This laptop is in the `sihooleebd@` tailnet; yulee is in
          `injoystickly@` and reaches us as a SHARED node, same as victus-15.
          Shared nodes get no short MagicDNS name -- `ssh yulee` does not
          resolve here, only the FQDN does. galaxybook4-pro360 is inside the
          peer's own tailnet, so it leaves this at the default and keeps using
          the bare name.
        */
        address = "yulee.tail2d4da1.ts.net";
      };
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [
        fastfetch
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

    /*
      Shell is Haku Space, not DMS -- mutually exclusive `provides = ["shell"]`
      claimants (features/_meta), so dms.enable must be false or the role
      assertion fires. The greeter is a SEPARATE switch (features/dms/nixos.nix:
      its config is gated on cfg.greeter.enable alone, not on cfg.enable) --
      it is DMS's dank-greeter login screen, unrelated to which shell runs once
      logged in, so it stays on here.
    */
    dms = {
      enable = false;
      greeter.enable = true;
    };

    hakuspace.enable = true;

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
