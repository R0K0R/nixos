{ config, lib, ... }:

{
  options.my.fcitxTrayText.enable = lib.mkEnableOption ''
    the fcitx tray icon as a themed TEXT label ("EN" / "한") in DepartureMono, not fcitx's own
    pixmap. Layered on the system's fcitx feature, which owns the rest of ~/.config/fcitx5
  '';

  config = lib.mkIf config.my.fcitxTrayText.enable {
    /*
      The tray icon as a themed TEXT label, not fcitx's own pixmap.

      Bar CSS colors font glyphs; a StatusNotifier tray icon is a bitmap the
      APP renders, and no stylesheet on the bar side can recolor it -- which is
      why every module matched the accent while fcitx's keyboard icon stayed
      its own colors. PreferTextIcon is fcitx's supported knob for exactly
      this: the tray renders the layout label ("EN" / "한") as text with these
      colors. White, matching the monochrome tray aesthetic -- the accent is
      wallpaper-dynamic and this file is static, so the accent itself is not
      reachable from here.

      Top-level keys, not sections -- classicui.conf's own format -- so no
      fcitx5Ini here.
    */
    xdg.configFile."fcitx5/conf/classicui.conf" = {
      force = true;
      text = ''
        PreferTextIcon=True
        TrayFont="DepartureMono Nerd Font 11"
        TrayTextColor=#ffffff
        TrayOutlineColor=#000000
      '';
    };
  };
}
