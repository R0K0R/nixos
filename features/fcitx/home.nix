{ config, lib, osConfig, ... }:


let
  # sharedModules are evaluated once per user; this is what makes the
  # feature apply only to the accounts my.fcitx.users names.
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "fcitx"; };
in
let
  fcitx5Ini = lib.generators.toINI { };

  fcitx5Cfg = {
    # TriggerKeys: full IME inactive/active; Hangul deliberately omitted (physical RAlt → Hangul via keyd).
    "Hotkey/TriggerKeys" = {
      "0" = "Control+space";
      "1" = "Zenkaku_Hankaku";
    };
    # EnumerateForwardKeys intentionally omitted: the Hangul toggle is a niri
    # compositor keybind (features/niri/home.nix) so it fires before any app can steal it.
    "Behavior".ActiveByDefault = true;
  };

  fcitx5Prof = {
    "Groups/0" = {
      Name = "Default";
      "Default Layout" = "us";
      DefaultIM = "keyboard-us";
    };
    "Groups/0/Items/0" = {
      Name = "keyboard-us";
      Layout = "";
    };
    "Groups/0/Items/1" = {
      Name = "hangul";
      Layout = "";
    };
    GroupOrder."0" = "Default";
  };
in
lib.mkIf (osConfig.my.fcitx.enable && inScope) {
  # Store-backed immutable fcitx5 config; the NixOS half builds fcitx5-with-addons
  # and the patched hangul addon. Global options and the IME profile live here so
  # the user dir is the single source of truth rather than merging /etc vs ~/.config.
  xdg.configFile."fcitx5/config" = {
    force = true;
    text = fcitx5Ini fcitx5Cfg;
  };
  xdg.configFile."fcitx5/profile" = {
    force = true;
    text = fcitx5Ini fcitx5Prof;
  };

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
}
