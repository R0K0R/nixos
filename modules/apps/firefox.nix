{ config, lib, pkgs, ... }:

{
  options.my.firefoxPortal.enable = lib.mkEnableOption ''
    Firefox's file dialogs routed through the XDG desktop portal (as an enterprise policy). The
    portal routing itself (FileChooser -> kde) is the system's session-services
  '';

  config = lib.mkIf config.my.firefoxPortal.enable {
    programs.firefox = {
      enable = true;
      # The same build the system's firefox feature uses (the Mozilla binary: the source build is
      # a multi-hour compile on a tuned host for no gain here). Without this home-manager would
      # install pkgs.firefox, a second Firefox that shadows the system's by PATH order.
      package = lib.mkDefault pkgs.firefox-bin;

      /*
        Force Firefox's file dialogs through the XDG desktop portal, which the system routes to the
        KDE backend -- so open/save use the same Dolphin-style picker (and it's dark, following the
        Qt theme) as the rest of the desktop, instead of Firefox's own light GTK chooser. Firefox has
        its OWN file-picker logic and ignores GTK_USE_PORTAL, so this pref is the only lever. 2 =
        always (0 = never, 1 = auto, which wasn't biting here).

        As a POLICY (Preferences, status "default") rather than a profile's user.js: home-manager
        needs a declared profile to write prefs, and the system's firefox feature leaves profiles
        alone. A policy wraps the binary itself, so it applies to whatever profile is in use and
        stays overridable in about:config.
      */
      policies.Preferences."widget.use-xdg-desktop-portal.file-picker" = {
        Value = 2;
        Status = "default";
      };
    };
  };
}
