{ pkgs, ... }:

/*
  Qt theming outside Plasma (dolphin, kdenlive, quickshell/DMS tray, ...).

  Three independent layers, each of which was broken in its own way -- all
  three had to be fixed before dolphin stopped being white-on-white:

  1. QT_QPA_PLATFORMTHEME=qt6ct (hyprland.nix env) selects the qt6ct
     platform theme plugin -- but plugin *discovery* needs the system
     profile's Qt plugin dir on QT_PLUGIN_PATH. Nothing provided that:
     the fcitx5 module sets QT_PLUGIN_PATH to just its own im-module dir,
     so libqt6ct.so (present in /run/current-system/sw/lib/qt-6/plugins/
     platformthemes/ via kdePackages.qt6ct) was never loadable by ANY app.
     The list below merges with fcitx5's entry (both are list options).

  2. qt6ct reads ~/.config/qt6ct/qt6ct.conf [Appearance]:
       - icon_theme= feeds QPlatformTheme::SystemIconThemeName, which
         QIcon::fromTheme() treats as authoritative -- quickshell's tray
         resolves StatusNotifier icon *names* (fcitx5's
         "input-keyboard-symbolic") through exactly this, so a missing
         icon_theme= is what produced the magenta/black checkerboard.
         (There is no QT_ICON_THEME env var in Qt at all -- an earlier
         attempted fix targeting it was a no-op.)
       - color_scheme_path= must point at a qt6ct-NATIVE scheme file
         ([ColorScheme] active_colors=... arrays). DMS upstream bugs
         (scripts/qt.sh): it points this at the KDE-format
         DankMatugen.colors file qt6ct silently can't parse, and its
         file-creation branch printf's literal "\n" (double-escaped in
         single quotes), producing a one-line corrupted conf. matugen
         DOES generate a proper native scheme at
         ~/.config/qt6ct/colors/matugen.conf -- qt6ct.conf just has to
         reference it. qt.sh's sed re-clobbers color_scheme_path on
         every theme change (icon_theme survives; only non-KDE Qt apps'
         palette regresses until qt.sh is fixed upstream).

  3. KDE Frameworks apps additionally run KColorSchemeManager, which
     outside Plasma picks its own scheme (default: light) and re-applies
     it OVER the platform-theme palette. Only kdeglobals
     [UiSettings] ColorScheme= steers it -- managed in home-manager
     (modules/home/r0k0r/gui/qt-theming.nix).
*/
{
  environment.profileRelativeSessionVariables.QT_PLUGIN_PATH = [
    "/${pkgs.qt6.qtbase.qtPluginPrefix}"
  ];
}
