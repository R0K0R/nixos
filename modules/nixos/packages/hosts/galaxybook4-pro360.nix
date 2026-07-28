{ pkgs, inputs, ... }:

let
  # Unpatched upstream nixpkgs, imported with allowUnfree so its prebuilt
  # (Hydra-cached) packages can be pulled in verbatim -- bypassing this
  # fork's pseudo-cross stdenv for things we don't want rebuilt from source.
  # legacyPackages.<pkg> would ignore this system's allowUnfree, so import
  # explicitly here.
  upstream = import inputs.nixpkgs-upstream {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
in
with pkgs;
[
  # claude-desktop, hash-pinned via the claude-desktop-bin flake input (see
  # flake.nix). Bump: modules/nixos/packages/claude-desktop/update.sh
  # [version], then rebuild.
  (callPackage ../claude-desktop/package.nix { src = inputs.claude-desktop-bin; })

  (writeScriptBin "nixos-rebuild-local" ''
    #! /bin/sh
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --builders "" \
      --option max-jobs 4 \
      --option substituters "https://cache.nixos.org" \
      "$@"
  '')

  (writeScriptBin "nixos-rebuild-yulee" ''
    #! /bin/sh
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --option max-jobs 0 \
      --builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 3 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

  (writeScriptBin "nixos-rebuild-victus-15" ''
    #! /bin/sh
    # No substituters override: cache.nixos.org used to be useless here because
    # the fork patched setup.sh and the cc/bintools wrappers unconditionally, so
    # every hash in the tree diverged from upstream -- even plain native `hello`
    # was absent from the binary cache. Those changes are now confined to the
    # stdenvs that need them, so BUILD-platform derivations are byte-identical
    # to upstream again and the cache genuinely serves them. Leaving the system
    # substituter list alone keeps cache.nixos.org in play; overriding it here
    # would forfeit that.
    # maxJobs 3 (third field after the key): 5 parallel builds drove victus
    # deep into swap -- LTO link steps in particular are memory-hungry.
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --option max-jobs 0 \
      --builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 3 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      "$@"
  '')

  (writeScriptBin "nix-shell-local" ''
    #! /bin/sh
    exec nix-shell \
      --option builders "" \
      --option max-jobs 4 \
      --option substituters "https://cache.nixos.org" \
      "$@"
  '')

  (writeScriptBin "nix-shell-yulee" ''
    #! /bin/sh
    exec nix-shell \
      --option max-jobs 0 \
      --option builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 3 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

  (writeScriptBin "nix-shell-victus-15" ''
    #! /bin/sh
    exec nix-shell \
      --option max-jobs 0 \
      --option builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 3 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@victus-15" \
      "$@"
  '')

  libreoffice

  ffmpeg-full
  rnote
  siril
  blender
  easyeffects
  moonlight-qt

  kdePackages.dolphin
  kdePackages.kdeconnect-kde
  kdePackages.qt6ct

  /*
    fcitx5 tray (Classic UI StatusNotifier): requests Icon `input-keyboard-symbolic` (see dbus
    `:…/StatusNotifierItem` IconName). That lives in KDE/GNOME themes, not in hicolor-only trees,
    otherwise QuickShell shows the magenta fallback tile.
  */
  kdePackages.breeze-icons
  adwaita-icon-theme
  # Base for Bibata-Modern-Classic-Glass (translucent variant built in
  # modules/home/r0k0r/gui/cursor.nix); also provides the solid variants.
  bibata-cursors
  google-chrome

  opencode
  opencode-claude-auth
  zoom-us

  # Arduino development (serial access needs the dialout group --
  # granted in hosts/galaxybook4-pro360/default.nix)
  arduino-cli

  discord

  # GPU / VA-API diagnostics
  libva-utils

  openjdk25_headless

  upstream.qemu

  # CPU / power monitoring
  powertop
  s-tui
  (kdePackages.kdenlive.overrideAttrs (prev: {
    nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
    postInstall = (prev.postInstall or "") + ''
      wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
    '';
  }))
]
