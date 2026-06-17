{ ... }:

{
  environment.sessionVariables = {
    ICON_THEME = "breeze-dark";
    GTK_ICON_THEME = "breeze-dark";
    # GTK_IM_MODULE intentionally unset: Fcitx5 waylandFrontend=true handles GTK4 and Qt6
    # via the native Wayland text-input-v3 protocol. GTK3 apps fall through to the same path.
    # Setting GTK_IM_MODULE=fcitx conflicts with Wayland IM and triggers Fcitx5's Wayland Diagnose.
    QT_IM_MODULE = "fcitx";
    XMODIFIERS = "@im=fcitx";
    MOZ_ENABLE_WAYLAND = "1";
  };
}
