{ lib, pkgs, inputs, hostName, ... }:

let
  hostRuntimeClassifier = import ../../modules/nixos/nix/host-runtime-classifier.nix {
    inherit inputs;
    host = hostName;
    system = "x86_64-linux";
  };
in
{
  imports = [
    ./hardware-configuration.nix
    ./hardware.nix
    ./fan-and-power.nix
    ./filesystems.nix
    ./packages.nix
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

  # Ryzen znver3 tuning. buildPlatform is declared WITHOUT gcc.arch so that it
  # differs from hostPlatform, which is what makes this an intra-ISA pseudo-cross
  # build rather than a native one -- same arrangement as galaxybook4-pro360.
  #
  # This is not tuning for its own sake: the split is what upstream-tools-overlay
  # keys off. Natively (host == build) there is only ONE package set, so that
  # overlay's guard falls through and it aliases *everything* to upstream, which
  # would silently delete the znver3/O3/LTO tuning entirely. With the split,
  # pkgsBuildHost is plain x86_64 and byte-identical to upstream (so build tools
  # substitute from cache.nixos.org), while pkgs stays znver3-tuned for anything
  # that actually runs here.
  nixpkgs.buildPlatform = "x86_64-linux";

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "znver3";
  };

  # mkOrder 1600 puts the alias overlay AFTER the default-ordered list below, so
  # the tuning overlays see fork packages and the aliasing happens last. Same
  # layering as galaxybook4-pro360.
  nixpkgs.overlays = lib.mkMerge [
    (lib.mkOrder 1600 [
      (import ../../modules/nixos/nix/upstream-tools-overlay.nix {
        inherit lib inputs hostRuntimeClassifier;
      })
    ])

    [
      (import ../../modules/nixos/nix/o3-overlay.nix { inherit hostRuntimeClassifier; })
      (import ../../modules/nixos/nix/gentoo-lto-overlay.nix { inherit hostRuntimeClassifier; })

      # F8 (ported from galaxybook4-pro360): fresh native i686 stdenv, bypassing
      # the pseudo-cross overlay. Pattern D.
      # Without this, pkgsi686Linux inherits the znver3 hostPlatform overlay →
      # triple-cross (BUILD=x86_64 → HOST=i686 → TARGET=i686 pseudo-cross) which
      # breaks 32-bit compat packages (mesa i686, libgcrypt i686, etc.) -- a
      # real, pre-existing nixpkgs defect in genuine x86_64->i686 cross builds,
      # confirmed reproducible on plain unpatched upstream nixpkgs too. Only
      # surfaced here because enable32Bit + the buildPlatform split together
      # first exercise a genuine (rather than native-reimport) pkgsi686Linux.
      (final: prev:
        let isZnver3Host = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "znver3";
        in lib.optionalAttrs isZnver3Host {
          pkgsi686Linux = import inputs.nixpkgs {
            localSystem = { system = "i686-linux"; };
            config = prev.config;
          };
        })
    ]
  ];

  boot.kernelPackages = pkgs.linuxPackages_latest;

  system.stateVersion = "26.05";
}
