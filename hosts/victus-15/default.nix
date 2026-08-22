{ pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix
    ./fan-and-power.nix
    ./filesystems.nix
  ];

  networking.hostName = "victus-15";

  my = {
    emacs = {
      enable = true;
      # No display manager and no compositor: terminal-only build, daemon on
      # default.target, reached with `emacsclient -nw` over ssh.
      headless = true;
    };

    # Was reaching this host via modules/nixos/packages/common.nix, which
    # victus-15 imports for its "complex derivations shared across both hosts"
    # list. Now an explicit feature, so it has to be asked for.
    claude-code.enable = true;

    /*
      Both humans on this machine. Declaring an account creates it, and the
      primary is what every feature's `users` option defaults to -- so benjamin
      gets an account and a home-manager configuration, but none of the features
      scoped to the primary unless he is named explicitly.

      hashedPasswordFile paths are not tracked in git (see secrets/ in
      .gitignore). They must exist at these exact paths on this machine; the
      activation script reads them at switch time and they are never embedded
      into the Nix store. users.mutableUsers = false below makes them mandatory,
      which features/users asserts.
    */
    users = {
      r0k0r = {
        primary = true;
        extraGroups = [ "networkmanager" "wheel" ];
        hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";
        shell = pkgs.fish;
      };

      benjamin = {
        description = "Benjamin S.H. Lee";
        extraGroups = [ "networkmanager" "wheel" ];
        hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-benjamin";
      };
    };

    /*
      btop with CUDA, replacing the plain btop that features/base contributes.
      Goes through my.packages.extra rather than users.users directly: extra is
      ordered mkOrder 100, so under buildEnv's ignoreCollisions first-wins it is
      deterministically the one on PATH, and features/packages emits a warning
      naming the shadowed package instead of leaving it to module import order.
    */
    packages.extra.user = with pkgs; [ (btop.override { cudaSupport = true; }) ];

    locale = {
      enable = true;
      # Fixed installation -- no geoclue2 here and nothing to gain from
      # relocating the clock, unlike the travel laptop.
      automatic = false;
      extraLocaleSettings = {
        LC_ADDRESS = "en_US.UTF-8";
        LC_IDENTIFICATION = "en_US.UTF-8";
        LC_MEASUREMENT = "en_US.UTF-8";
        LC_MONETARY = "en_US.UTF-8";
        LC_NAME = "en_US.UTF-8";
        LC_NUMERIC = "en_US.UTF-8";
        LC_PAPER = "en_US.UTF-8";
        LC_TELEPHONE = "en_US.UTF-8";
        LC_TIME = "en_US.UTF-8";
      };
    };

    nix-settings = {
      enable = true;
      substituters = [
        "https://cache.nixos.org"
        "https://cuda-maintainers.cachix.org"
      ];
      trustedPublicKeys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      ];
      # A host file naming its own human is fine -- that is what host files are
      # for. The invariant this refactor establishes is that FEATURES must not.
      trustedUsers = [ "r0k0r" ];
      secretKeyFiles = [ "/etc/nix/signing-key.pem" ];
    };

    network.enable = true;
    boot.enable = true;
    base.enable = true;

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.system = with pkgs; [
      vim
      git
      gh
      tailscale
      nbfc-linux   # fan control, driven by fan-and-power.nix
      ryzenadj     # power limits, same
    ];

    /*
      Same intra-ISA pseudo-cross arrangement as galaxybook4-pro360, only the
      arch differs. It used to be ~50 lines duplicated in this file, including
      its own copy of the i686 escape hatch guarded on "znver3" rather than
      "meteorlake" -- the same fix written twice because there was nowhere
      shared to put it.

      qtPatches stays off: pkgs-config.nix is meteorlake-specific qtbase
      patching and yulee-sandbox test exclusions, none of which applies here.
    */
    tuning = {
      # Literal, and it must stay one -- see the note in galaxybook4-pro360.
      enable = true;
      march = "znver3";
      pseudoCross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      refreshTool.enable = true;
    };
  };

  /*
    Declared accounts are the whole truth here, so every one of them needs a
    hashedPasswordFile or it becomes unloginnable at the first switch --
    features/users asserts exactly that. root is not a my.users account (it is
    not a human), so its hash is set directly.
  */
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";

  programs.fish.enable = true;

  networking.firewall.enable = false;
  services.openssh.enable = true;

  services.tailscale = {
    enable = true;
    authKeyFile = "/var/lib/tailscale/authkey";
  };

  # Clamshell mode -- this host runs closed-lid as a remote builder.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
