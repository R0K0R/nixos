/*
  fcitx5's own config: the trigger keys and the Hangul profile.

  The home half of fcitx, moved from the system's features/session/fcitx on
  2026-10-27. The system half keeps the same name and does what needs root;
  this asserts it is on.
*/
{ config, lib, osConfig, ... }:


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
{
  options.my.fcitx.enable = lib.mkEnableOption "fcitx5's own config: the trigger keys and the Hangul profile";

  config = lib.mkIf config.my.fcitx.enable {
    assertions = [
      {
        assertion = osConfig.my.fcitx.enable or false;
        message = "my.fcitx needs its system half on this host (my.fcitx in the system's host file).";
      }
    ];
    my.persist.directories = [
      ".local/share/fcitx5" # learned hangul and user dictionary data
    ];

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
  };
}
