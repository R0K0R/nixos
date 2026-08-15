/*
  Single source of truth for "plain package reference" lists -- i.e. every
  package here is just an attribute lookup into the passed `pkgs`, never a
  locally-built derivation (writeScriptBin wrappers, overrideAttrs, etc).
  Those stay in their own per-host files (e.g.
  modules/nixos/packages/hosts/galaxybook4-pro360.nix) and get concatenated
  alongside whatever this file provides.

  Three sections match the three distinct NixOS/home-manager options these
  feed, not an arbitrary grouping:
    system     -> environment.systemPackages
    account    -> users.users.r0k0r.packages
    homeManager -> home.packages

  Consumed twice, by design:
    - normal callers pass the real, overlaid `pkgs` to get actual installable
      derivations (modules/nixos/packages/default.nix,
      modules/home/r0k0r/packages/default.nix, hosts/victus-15/packages.nix).
    - host-runtime-classifier.nix passes a fresh, fixpoint-safe `pkgs` import
      instead, to build its runtime-reachability anchor set. That replaces a
      hand-maintained name list that had already drifted (missing packages,
      wrong sibling of a multi-derivation project, names for things nothing
      installs) -- see host-runtime-classifier.nix's own comment for the
      cross-referencing this used to require by hand.
*/
{ pkgs }:

{
  system = {
    common = with pkgs; [
      wget
      openvpn
      upower
      jq
    ];

    galaxybook4-pro360 = with pkgs; [
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
      kdePackages.breeze-icons
      adwaita-icon-theme
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


      # CPU / power monitoring
      powertop
      s-tui

      poppler-utils
    ];

    "victus-15" = with pkgs; [
      vim
      git
      tailscale
      nbfc-linux
      ryzenadj
      gh
    ];
  };

  account = {
    common = with pkgs; [
      cursor-cli
      kitty
      fish
      git
      gh
      starship
      nixd
      statix
      deadnix
      tree
      python3
      # Python LSP for Emacs `lsp-pyright` when using BasedPyright (`basedpyright-langserver`).
      basedpyright
      clang-tools # clangd LSP + clang-format/clang-tidy
      gcc
      gdb
      flutter
      dart
      tinymist
      typst
    ];

    galaxybook4-pro360 = with pkgs; [
      nixfmt

      # Explicit package list instead of scheme-medium: names every LaTeX
      # package actually used rather than relying on a broad bundled scheme.
      # dvisvgm and asymptote are both kept (both pull in qt5.qtbase as a
      # runtime dep via wrap-qt5-apps-hook) since both are actually used here.
      (texlive.combine {
        inherit (texlive)
          scheme-small
          graphics
          amsmath
          amsfonts
          latexmk
          geometry
          hyperref
          xcolor
          booktabs
          caption
          enumitem
          microtype
          csquotes
          pgf
          biblatex
          listings
          dvisvgm
          asymptote
          ;
      })
      biber
    ];
  };

  homeManager = {
    common = with pkgs; [
      eza
    ];
  };
}
