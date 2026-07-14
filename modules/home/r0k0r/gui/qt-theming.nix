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
    kdeglobals="$HOME/.config/kdeglobals"
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
    # kdeglobals gets the FULL color groups, like Plasma writes when a
    # scheme is applied: Kirigami/QML apps (kdeconnect-app, ...) read
    # [Colors:*] straight from kdeglobals and never consult
    # [UiSettings]/KColorSchemeManager, so the pointer alone leaves them
    # on the default light palette.
    {
      printf '%s\n' '[UiSettings]' 'ColorScheme=DankMatugenBlack' \
        "" '[Icons]' 'Theme=breeze' ""
      cat "$dst"
    } > "$kdeglobals".tmp
    mv "$kdeglobals".tmp "$kdeglobals"
  '';
in

/*
  KDE-app half of Qt theming outside Plasma (system half + full debugging
  story: modules/nixos/desktop/qt-theming.nix).

  Two distinct consumers of KDE color config, both light-by-default
  outside Plasma:
    - KXmlGui widget apps (dolphin, kdenlive): KColorSchemeManager
      re-applies its own scheme choice OVER the platform theme's palette;
      only kdeglobals [UiSettings] ColorScheme= steers it (loads the
      scheme by name from ~/.local/share/color-schemes/).
    - Kirigami/QML apps (kdeconnect-app): no KColorSchemeManager; they
      read the [Colors:*] groups directly from kdeglobals, so kdeglobals
      must contain the full groups (exactly what Plasma writes on scheme
      apply).
  The generator script therefore rewrites BOTH the derived scheme file
  and a full kdeglobals from it -- kdeglobals is generated, not an HM
  store symlink, so the path-unit refresh keeps Kirigami apps in sync
  with wallpaper changes too.

  [Icons] Theme= covers KIconLoader lookups (file/folder icons inside KDE
  apps); the tray's name-based lookups are covered by qt6ct.conf's
  icon_theme= instead.
*/
{
  # Regenerate scheme + kdeglobals whenever matugen rewrites the source
  # scheme (theme/wallpaper change), once at login, and once per HM
  # activation (initial seed).
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
  home.activation.kdeglobalsSeed = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${genBlackScheme}
  '';

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
