{ config, lib, ... }:

let
  cfg = config.my.locale;
in
{
  options.my.locale = {
    enable = lib.mkEnableOption "timezone handling and locale defaults";

    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "Asia/Seoul";
      description = ''
        Fallback timezone. Applied at mkDefault priority -- see `automatic`.
      '';
    };

    automatic = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Track the timezone from geolocation via automatic-timezoned, so the
        system clock stays correct after flying without a manual
        `timedatectl set-timezone`.

        Requires geoclue2, which the session-services feature enables.

        A headless machine that never moves should set this false -- it has no
        geoclue2 and nothing to gain from relocating its clock.
      '';
    };

    defaultLocale = lib.mkOption {
      type = lib.types.str;
      default = "en_US.UTF-8";
      description = "i18n.defaultLocale.";
    };

    extraLocaleSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { LC_TIME = "en_US.UTF-8"; };
      description = "Per-category locale overrides (LC_*).";
    };

    xkbLayout = lib.mkOption {
      type = lib.types.str;
      default = "us";
      description = "Keyboard layout, applied to X and inherited by the console.";
    };

    xkbVariant = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Keyboard layout variant.";
    };
  };

  config = lib.mkIf cfg.enable {
    /*
      automatic-timezoned sets time.timeZone = null at NORMAL priority once
      enabled, so the fallback below must stay mkDefault (lower priority) --
      otherwise the module raises a conflict error, which it explicitly checks
      for (see services.automatic-timezoned's own option documentation).
    */
    time.timeZone = lib.mkDefault cfg.timeZone;
    services.automatic-timezoned.enable = cfg.automatic;

    i18n.defaultLocale = cfg.defaultLocale;
    i18n.extraLocaleSettings = cfg.extraLocaleSettings;

    services.xserver.xkb = {
      layout = cfg.xkbLayout;
      variant = cfg.xkbVariant;
    };
  };
}
