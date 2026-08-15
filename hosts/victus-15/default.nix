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

    user-r0k0r = {
      enable = true;
      mutableUsers = false;
      extraGroups = [ "networkmanager" "wheel" ];
      # Not tracked in git -- see secrets/ in .gitignore. Must exist at this
      # exact path on this machine; read by the activation script at switch
      # time, never embedded into the Nix store.
      hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";
      shell = pkgs.fish;
    };

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
      march = "znver3";
      pseudoCross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      refreshTool.enable = true;
    };
  };

  # Remaining users are host-specific: a second human account and root's own
  # hash. r0k0r itself comes from my.user-r0k0r above.
  users.users = {
    r0k0r.packages = with pkgs; [ (btop.override { cudaSupport = true; }) ];
    benjamin = {
      isNormalUser = true;
      description = "Benjamin S.H. Lee";
      extraGroups = [ "networkmanager" "wheel" ];
      hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-benjamin";
      packages = [ ];
    };
    root.hashedPasswordFile = "/etc/nixos/secrets/victus-15-hashed-password-r0k0r";
  };

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
