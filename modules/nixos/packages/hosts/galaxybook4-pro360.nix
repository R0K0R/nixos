{ pkgs, ... }:

with pkgs; [
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
      --builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 10 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

  (writeScriptBin "nixos-rebuild-victus-15" ''
    #! /bin/sh
    exec nixos-rebuild \
      --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
      --option max-jobs 0 \
      --builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 5 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@victus-15" \
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
      --option builders "ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 10 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@yulee" \
      "$@"
  '')

  (writeScriptBin "nix-shell-victus-15" ''
    #! /bin/sh
    exec nix-shell \
      --option max-jobs 0 \
      --option builders "ssh://r0k0r@victus-15 x86_64-linux /etc/nix/remote-builder/ssh_key 5 10 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake" \
      --option substituters "https://cache.nixos.org ssh://r0k0r@victus-15" \
      "$@"
  '')

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
  google-chrome

  opencode
  opencode-claude-auth
  zoom

  # GPU / VA-API diagnostics
  libva-utils

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
