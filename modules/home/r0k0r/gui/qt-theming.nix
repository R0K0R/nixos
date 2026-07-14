{
  config,
  lib,
  pkgs,
  ...
}:

let
  /*
    Derived scheme: matugen's accents, but pure-black window/view/header
    backgrounds so dolphin's glass tint matches kitty/emacs (both sit on
    #000000; DankMatugen's 19,19,21 base reads visibly warmer through the
    same 0.65 opacity). Regenerated whenever matugen rewrites the source
    scheme (path unit below), so accents track the wallpaper.
  */
  genBlackScheme = pkgs.writeShellScript "gen-dankmatugen-black" ''
    src="$HOME/.local/share/color-schemes/DankMatugen.colors"
    dst="$HOME/.local/share/color-schemes/DankMatugenBlack.colors"
    [ -f "$src" ] || exit 0
    ${pkgs.gawk}/bin/awk '
      /^\[/ { sect = $0 }
      sect ~ /^\[Colors:(View|Window|Header)/ && /^BackgroundNormal=/ {
        print "BackgroundNormal=0,0,0"; next
      }
      sect ~ /^\[Colors:(View|Window|Header)/ && /^BackgroundAlternate=/ {
        print "BackgroundAlternate=13,13,13"; next
      }
      /^ColorScheme=DankMatugen$/ { print "ColorScheme=DankMatugenBlack"; next }
      /^Name=/ { print "Name=Dank Shell (matugen, black bg)"; next }
      { print }
    ' "$src" > "$dst"
  '';
in

/*
  KDE-app half of Qt theming outside Plasma (system half + full debugging
  story: modules/nixos/desktop/qt-theming.nix).

  KDE Frameworks apps (dolphin, kdenlive, ...) run KColorSchemeManager,
  which outside Plasma ignores the platform theme's palette and re-applies
  its own scheme choice -- default light, hence dolphin staying white even
  with qt6ct's dark palette confirmed loaded. [UiSettings] ColorScheme= is
  the one knob it honors: at app startup it loads that scheme by name from
  ~/.local/share/color-schemes/ (where DMS's matugen writes
  DankMatugen.colors on every theme change) and applies the palette from
  the FILE, so colors stay in sync with the wallpaper without copying
  [Colors:*] groups here (a static copy would go stale and fight it).

  [Icons] Theme= covers KIconLoader lookups (file/folder icons inside KDE
  apps); the tray's name-based lookups are covered by qt6ct.conf's
  icon_theme= instead.
*/
{
  xdg.configFile."kdeglobals" = {
    force = true;
    text = ''
      [UiSettings]
      ColorScheme=DankMatugenBlack

      [Icons]
      Theme=breeze
    '';
  };

  # Regenerate the black-background scheme whenever matugen rewrites the
  # source scheme (theme/wallpaper change), and once at login for the
  # initial copy.
  systemd.user.services.dankmatugen-black = {
    Unit.Description = "Derive DankMatugenBlack.colors from DankMatugen.colors";
    Service = {
      Type = "oneshot";
      ExecStart = "${genBlackScheme}";
    };
    Install.WantedBy = [ "default.target" ];
  };
  systemd.user.paths.dankmatugen-black = {
    Unit.Description = "Watch matugen KDE color scheme for changes";
    Path.PathChanged = "%h/.local/share/color-schemes/DankMatugen.colors";
    Install.WantedBy = [ "default.target" ];
  };

  /*
    qt6ct.conf can NOT be a store symlink: DMS's scripts/qt.sh runs sed -i
    on it at every theme change, which would replace the symlink with a
    mutated regular file and break the next HM activation. Instead enforce
    the two keys qt.sh gets wrong (see the nixos-side module for the
    upstream bug details), leaving the file writable:
      - icon_theme=  : qt.sh never writes it; without it the qt6ct
        platform theme hands Qt an EMPTY icon theme (tray checkerboard).
      - color_scheme_path= : qt.sh points it at the KDE-format .colors
        file qt6ct can't parse; the qt6ct-native scheme matugen generates
        is colors/matugen.conf. qt.sh re-clobbers this one on every theme
        change, so this repairs it on each activation as well.
    Also rewrites from scratch if the file is missing or corrupted by
    qt.sh's broken printf (literal backslash-n, no real newlines).
  */
  home.activation.qt6ctConf = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    conf="${config.xdg.configHome}/qt6ct/qt6ct.conf"
    scheme="${config.xdg.configHome}/qt6ct/colors/matugen.conf"
    run mkdir -p "$(dirname "$conf")"
    if [ ! -f "$conf" ] || ! grep -q '^\[Appearance\]$' "$conf"; then
      run printf '%s\n' '[Appearance]' 'custom_palette=true' \
        "color_scheme_path=$scheme" 'icon_theme=breeze' > "$conf"
    else
      if grep -q '^icon_theme=' "$conf"; then
        run sed -i 's|^icon_theme=.*|icon_theme=breeze|' "$conf"
      else
        run sed -i '/^\[Appearance\]$/a icon_theme=breeze' "$conf"
      fi
      if grep -q '^color_scheme_path=' "$conf"; then
        run sed -i "s|^color_scheme_path=.*|color_scheme_path=$scheme|" "$conf"
      else
        run sed -i "/^\[Appearance\]$/a color_scheme_path=$scheme" "$conf"
      fi
    fi
  '';
}
