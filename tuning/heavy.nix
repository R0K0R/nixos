/*
  my.tuning.heavy -- the explicit list of packages worth ccache, mold and
  dropping debug info for, and the overlay that applies them (overlays/heavy.nix).

  Explicit rather than global on purpose. ccache only pays back when the SAME
  derivation is rebuilt, and swapping a package's stdenv rebuilds it and
  everything above it once; for the long tail of small, build-once packages
  that is all cost and no return. The list below is "aggressive": every tuned
  (actually-compiled-here) package that is heavy or medium, grouped by the
  mechanism its stdenv is reached through. Packages the classifier aliases to
  upstream (chromium, firefox, electron, jdk, ...) are absent because they are
  substituted, never compiled.

  THE CASCADE, stated once: glib, openssl, icu, python3, perl sit near the root
  of the host graph. Including them means a one-time rebuild of essentially
  the whole tuned closure on both builders. Accepted deliberately; paid once.
*/
{ config, lib, ... }:

let
  cfg = config.my.tuning.heavy;
  entry = lib.types.attrsOf lib.types.anything;
in
{
  options.my.tuning.heavy = {
    enable = lib.mkEnableOption "ccache / mold / no-debug-info treatment of the heavy package list";
    mold.enable = lib.mkEnableOption "linking the heavy list with mold (stdenvAdapters.useMoldLinker)" // { default = true; };
    noDebugInfo.enable = lib.mkEnableOption "separateDebugInfo = false on the heavy list (drops -ggdb; webkit's 460 MB of DWARF)" // { default = true; };

    packages = lib.mkOption {
      type = lib.types.listOf entry;
      description = ''
        Entries are `{ attr; stdenvArg ? "stdenv"; via ? null; mold ? true; noDebugInfo ? true; }`
        for top-level packages, or `{ scope; members ? null; mold ? true; }` for a
        makeScope -- the whole scope's stdenv (qt6, kdePackages) or just the
        named members (llvmPackages.llvm). `via` names a passthru holding the real build
        behind a wrapper (libreoffice-qt-stable.unwrapped). `attr = "buildLinux"`
        reaches every kernel built from the overlay.
      '';
      default = [
        # --- the original three
        { attr = "webkitgtk_4_1"; stdenvArg = "clangStdenv"; }
        { attr = "webkitgtk_6_0"; stdenvArg = "clangStdenv"; }
        { attr = "libreoffice-qt-stable"; via = "unwrapped"; }
        { attr = "buildLinux"; noDebugInfo = false; }          # the kernel; not a derivation itself
        # --- whole scopes: qtwebengine, qtdeclarative, qtbase ... and all KDE frameworks/apps
        { scope = "qt6"; }
        { scope = "kdePackages"; }
        # --- big C/C++ leaves
        { attr = "blender"; }
        { attr = "qemu"; }
        { scope = "llvmPackages"; members = [ "llvm" ]; }   # llvm only; not the scope stdenv (that is clangStdenv's ancestry)
        { attr = "opencv"; }
        { attr = "ffmpeg-full"; }
        { attr = "ffmpeg"; }
        { attr = "imagemagick"; }
        { attr = "poppler"; }
        { attr = "emacs-pgtk"; }
        # hyprland applies stdenvAdapters.useMoldLinker itself; don't double it
        { attr = "hyprland"; stdenvArg = "gcc16Stdenv"; mold = false; }
        # --- medium libraries with many TUs
        { attr = "mesa"; }
        { attr = "gtk4"; }
        { attr = "gtk3"; }
        { attr = "pango"; }
        { attr = "harfbuzz"; }
        { attr = "icu"; }
        { attr = "systemd"; }
        { attr = "pipewire"; }
        { attr = "boost"; }
        { attr = "protobuf"; }
        { attr = "abseil-cpp"; }
        { attr = "curlMinimal"; } # `curl` is curlMinimal.override { .. }; follows
        # --- deep roots: the cascade lives here
        { attr = "glib"; }
        { attr = "openssl"; }
        { attr = "python3"; }
        { attr = "perl"; }
      ];
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.my.tuning.enable && config.my.tuning.march != null;
        message = "my.tuning.heavy needs my.tuning.enable and a march: the overlay only touches the march'd host set.";
      }
    ];

    # mkBefore: must precede o3.nix / gentoo-lto.nix -- see overlays/heavy.nix.
    nixpkgs.overlays = lib.mkBefore [
      (import ./overlays/heavy.nix {
        inherit lib;
        ccache = {
          enable = config.my.ccache.enable;
          extraConfig = config.my.ccache.wrapperConfig;
        };
        mold = cfg.mold.enable;
        noDebugInfo = cfg.noDebugInfo.enable;
        entries = cfg.packages;
      })
    ];
  };
}
