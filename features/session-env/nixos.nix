{ config, lib, ... }:

let
  cfg = config.my.session-env;
in
{
  options.my.session-env.enable = lib.mkEnableOption ''
    graphical session environment variables: icon theme, Qt/X input-method
    routing, and native Wayland for Firefox and Electron apps
  '';

  config = lib.mkIf cfg.enable {
    environment.sessionVariables = {
      ICON_THEME = "breeze-dark";
      GTK_ICON_THEME = "breeze-dark";
      # GTK_IM_MODULE intentionally unset: Fcitx5 waylandFrontend=true handles GTK4 and Qt6
      # via the native Wayland text-input-v3 protocol. GTK3 apps fall through to the same path.
      # Setting GTK_IM_MODULE=fcitx conflicts with Wayland IM and triggers Fcitx5's Wayland Diagnose.
      QT_IM_MODULE = "fcitx";
      XMODIFIERS = "@im=fcitx";
      MOZ_ENABLE_WAYLAND = "1";
      # Electron/Chromium (Discord, Chrome, VS Code, ...) go native Wayland
      # instead of XWayland. Without this they render at 1x under XWayland and
      # the compositor bitmap-upscales to the 1.5 monitor scale -> blurry text.
      # nixpkgs' Electron wrappers gate their --ozone-platform=wayland flags on
      # this var (+ WAYLAND_DISPLAY). Verified live on Discord: blurry -> crisp.
      NIXOS_OZONE_WL = "1";
    };
  };
}
