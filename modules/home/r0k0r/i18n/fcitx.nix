{ lib, ... }:

let
  fcitx5Ini = lib.generators.toINI { };

  fcitx5Cfg = {
    # TriggerKeys: full IME inactive/active; Hangul deliberately omitted (physical RAlt → Hangul via keyd).
    "Hotkey/TriggerKeys" = {
      "0" = "Control+space";
      "1" = "Zenkaku_Hankaku";
    };
    # EnumerateForwardKeys intentionally omitted: the Hangul toggle is a niri
    # compositor keybind (wayland/niri.nix) so it fires before any app can steal it.
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
{
  # Store-backed immutable fcitx5 config (`configuration.nix` still builds fcitx5-with-addons + patched hangul).
  xdg.configFile."fcitx5/config" = {
    force = true;
    text = fcitx5Ini fcitx5Cfg;
  };
  xdg.configFile."fcitx5/profile" = {
    force = true;
    text = fcitx5Ini fcitx5Prof;
  };
}
