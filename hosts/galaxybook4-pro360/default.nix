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
    tuning = {
      march = "meteorlake";
      pseudoCross.enable = true;
      o3.enable = true;
      lto.enable = true;
      upstreamTools.enable = true;
      qtPatches.enable = true;
      refreshTool.enable = true;
    };

    user-r0k0r.enable = true;
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
      hosts = {
        yulee = { };
        victus-15 = { };
        note10.Port = 8022;
      };
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
    astro.enable = true;
    desktop-apps.enable = true;
    arduino.enable = true;
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

    remote-builder.client = {
      enable = true;
      wrappers.enable = true;
      # yulee omitted while parked -- an unreachable substituter costs a
      # timeout on every lookup.
      substituters = [ "ssh://r0k0r@victus-15" ];
      trustedPublicKeys = [
        "yulee-1:KgdwkCN5m+hewJTk+A05PjwI3BbnZAE9NW2n634N7vM="
        "victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ="
      ];
      peers = {
        yulee = {
          # PARKED: unreachable since 2026-08. Left declared rather than
          # deleted so it comes back with one word. While false it is absent
          # from /etc/nix/machines, which is the only thing that actually stops
          # the daemon dispatching eval-time IFD builds to it.
          enable = false;
          maxJobs = 7;
          speedFactor = 10;
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" "gccarch-meteorlake" ];
        };
        victus-15 = {
          maxJobs = 5;
          speedFactor = 4;
          features = [ "benchmark" "big-parallel" "kvm" "nixos-test" "gccarch-meteorlake" ];
        };
      };
    };
    /*
      Goodix GXTP7936 panel. by-path, not eventN: event numbers are assigned in
      probe order and move between boots.
    */
    touch-gestures = {
      enable = true;
      device = "/dev/input/by-path/pci-0000:00:15.1-platform-i2c_designware.1-event";
    };

    /*
      One-offs that do not justify a feature. Literal list -- see
      my.packages.extra's own docs on why lookup.nix cannot read a mkIf here.
    */
    packages.extra.user = with pkgs; [
      rquickshare # Google Quick Share client, for phone <-> laptop transfers
      galaxy-buds-client
    ];

    samsung-galaxybook.enable = true;
    power.enable = true;
    flatpak.enable = true;
    flamenco.enable = true;
    easyeffects.enable = true;

    boot = {
      enable = true;
      extraEntries = {
        "windows.conf" = ''
          title Windows
          efi /EFI/Microsoft/Boot/bootmgfw.efi
          sort-key o_windows
        '';
        "netboot.conf" = ''
          title Netboot
          efi /EFI/netboot/netboot.xyz.efi
          sort-key o_netboot
        '';
        "asclepius.conf" = ''
          title Asclepius
          efi /EFI/Asclepius/bootx64.efi
          sort-key o_asclepius
        '';
      };
    };

    emacs.machineLocalElisp = ''
      ;;; -*- lexical-binding: t; -*-
      ;;; Loaded by Doom `config.el` from ~/.config/home-manager/doom-machine-local.el

      (defun my/machine-local-reset-fonts-h ()
        (setq doom-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 13 :weight 'semi-light)
              doom-variable-pitch-font (font-spec :family "JetBrainsMonoNL Nerd Font" :size 13))
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
      primaryOutputScale = "1.5";
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

  networking.hostName = "galaxybook4-pro360";

  # Declare the local-Qt6 build capability so packages with
  # requiredSystemFeatures = ["galaxybook-local-qt6"] can build here.
  nix.settings.system-features = [ "galaxybook-local-qt6" ];

  nixpkgs.buildPlatform = "x86_64-linux";

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "meteorlake";
  };

  # Serial access for arduino-cli/arduino-ide (/dev/ttyACM*, /dev/ttyUSB*).
  users.users.r0k0r.extraGroups = [ "dialout" ];

  /*
    Galaxy Buds client in the tray from login. /StartMinimized is the app's
    own flag, read straight out of the shipped GalaxyBudsClient.dll (its
    settings UI calls it "Start minimized on system boot") -- without it the
    main window opens on every login. systemd user service on
    graphical-session.target, same pattern as lisgd and dms.service:
    compositor-agnostic (uwsm activates the target under both hyprland and
    niri), unlike an exec-once in one compositor's config. Host file, not a
    feature: single app, single host, pairs with the packages.extra entry
    above.
  */
  systemd.user.services.galaxy-buds-client = {
    description = "Galaxy Buds client (tray)";
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    wantedBy = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.galaxy-buds-client} /StartMinimized";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  /*
    Host-specific overlays only. Everything generic -- the pseudo-cross and
    build-load fixes, o3/LTO, upstream-tools, the i686 escape hatch -- moved to
    tuning/, behind the my.tuning.* switches above. What is left is about this
    machine's hardware and nothing else, which is why it cannot be shared.
  */
  my.tuning.extraOverlays = [
    # niri's own package set, needed wherever the niri compositor is selected.
    inputs.feat-niri.overlay

    # Meteor Lake-P integrated graphics (Intel Arc Graphics, PCI 8086:7d55)
    # is the only GPU on this laptop — no discrete AMD/NVIDIA to support.
    # Mesa's default driver lists build ~24 gallium + ~12 vulkan backends "to
    # support cross tools and emulation use cases"; trim to just what this
    # hardware needs plus a software fallback (llvmpipe/swrast — blender's own
    # test derivation uses mesa.llvmpipeHook, so keep that one rather than
    # dropping software rendering entirely).
    (final: prev: {
      mesa =
        (prev.mesa.override {
          galliumDrivers = [ "iris" "llvmpipe" ];
          vulkanDrivers = [ "intel" "swrast" ];
        }).overrideAttrs
          (old: {
            # nixpkgs' mesa flags assume the full default driver list; with the
            # trim above, three of them break or turn into dead weight (meson
            # takes the LAST occurrence of a -D flag, so appending overrides):
            mesonFlags = (old.mesonFlags or [ ]) ++ [
              # -Dauto_features=enabled force-enables the VA-API state tracker,
              # whose meson require() only accepts r600/radeonsi/nouveau/d3d12/
              # virgl -- hard configure error with iris-only. Intel VA-API is
              # provided by intel-media-driver, not mesa, so nothing is lost.
              "-Dgallium-va=disabled"
              # TFLite delegate hard-links the etnaviv/rocket/ethosu NPU
              # drivers (src/gallium/targets/teflon), all trimmed away.
              "-Dteflon=false"
              # Tools for asahi/panfrost, drivers this machine doesn't build.
              "-Dtools="
            ];
            # The spirv2dxil binary/libs only get built with the d3d12/dozen
            # drivers (trimmed away), and moveToOutput silently no-ops on
            # missing sources -- leaving the declared $spirv2dxil output
            # never created, which Nix rejects ("failed to produce output
            # path"). Same hazard for $cross_tools (pco_clc belongs to the
            # trimmed PowerVR driver). Empty outputs are valid; guarantee
            # they exist.
            postInstall = (old.postInstall or "") + ''
              mkdir -p $spirv2dxil $cross_tools
            '';
          });
    })

    /*
      Fingerprint sensor (USB 1c7a:05a1, Egis Technology "Match-On-Chip") enrolls
      and verifies successfully but forgets the print immediately: upstream
      libfprint's egismoc driver doesn't implement SDCP (Secure Device
      Communication Protocol), which these newer Egis MOC sensors require for
      the enrolled template to actually be committed to the sensor's own
      storage — enrollment silently "succeeds" without ever writing anything.
      TenSeventy7/libfprint-egismoc-sdcp implements SDCP support (device table
      confirms 0x05a1); no other patches needed (nixpkgs' libfprint has no
      patches of its own beyond build-system shebang/cross fixups, and openssl
      — the fork's one new hard dependency for SDCP's crypto handshake — is
      already a buildInput).
    */
    (final: prev: {
      libfprint = prev.libfprint.overrideAttrs (old: {
        src = prev.fetchFromGitHub {
          owner = "TenSeventy7";
          repo = "libfprint-egismoc-sdcp";
          rev = "4d128d4f6f0b46182572126e84df88a73ac27859";
          sha256 = "130b1dap0sxysg3grm5yk3fl7l072qv4vsiv9h6s69ln5gka0gwa";
        };
        # nixpkgs has since grown patches on libfprint, all of them new-hardware
        # USB product IDs (realtek-3274-9003, elan-0c58, elan-04F3-0C9C,
        # focal-077a-079a, focal-a97a) that don't apply to this fork's tree and
        # are for sensors this machine doesn't have (ours is the Egis 1c7a:05a1
        # the fork itself supports). The cross fixups live in postPatch, which
        # this override leaves intact.
        patches = [ ];
      });
    })
  ];
}
