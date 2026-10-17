{ config, lib, pkgs, ... }:

let
  cfg = config.my.kakaotalk-system;
in
{
  options.my.kakaotalk-system.enable = lib.mkEnableOption ''
    the system side of running KakaoTalk under Wine: Korean fonts, the ko_KR
    locale and a blocklist for its ad banners. The Wine app itself is not here
    -- it is a user program (a home's package, or my.kakaotalk, which carries
    its own fonts and does not need this)
  '';

  config = lib.mkIf cfg.enable {
    # Korean fonts, system-level (fontconfig) so Wine/Pango can resolve them --
    # otherwise KakaoTalk (and Hangul anywhere) renders as tofu boxes. Merges
    # with the fonts feature's own list.
    fonts.packages = with pkgs; [ nanum baekmuk-ttf ];

    # Build the Korean locale so the launcher can run KakaoTalk under
    # LANG=ko_KR.UTF-8: Wine derives its Windows ANSI codepage from LANG/LC_ALL
    # (en_US -> cp1252 mangles Hangul into tofu; ko_KR -> cp949 renders it).
    # supportedLocales REPLACES the default list (it's an mkDefault), so carry
    # the base two forward -- defaultLocale (from my.locale) + C -- alongside
    # ko_KR.
    i18n.supportedLocales = [
      "C.UTF-8/UTF-8"
      "${config.i18n.defaultLocale}/UTF-8"
      "ko_KR.UTF-8/UTF-8"
    ];

    # Blackhole KakaoTalk's ad banners (Kakao/Daum AdFit network). Wine resolves
    # through the Linux stack, so the prefix's Windows hosts file is ignored, but
    # /etc/hosts wins anyway -- nsswitch checks `files` before `dns`, so this
    # beats a MagicDNS/systemd-resolved resolver too. ad.daum.net +
    # info.ad.daum.net are baked into the KakaoTalk binary; display/analytics are
    # the same ad-only subdomain family. NOT t1.daumcdn.net -- that CDN also
    # serves emoticons/images. Restart KakaoTalk after a switch for the banner to
    # vanish.
    networking.extraHosts = ''
      0.0.0.0 ad.daum.net
      0.0.0.0 info.ad.daum.net
      0.0.0.0 display.ad.daum.net
      0.0.0.0 analytics.ad.daum.net
    '';
  };
}
