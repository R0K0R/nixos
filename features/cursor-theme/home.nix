{ pkgs, lib, osConfig, ... }:

let
  # Match the glass system (dolphin/kitty windows sit at 0.65).
  alpha = "1";

  /*
    "Glass" Bibata: Bibata-Modern-Classic (the Mint 21.1 look) with every
    frame's alpha multiplied down. XCursor themes are pre-rendered PNGs,
    so translucency is a post-process: unpack each cursor (xcur2png),
    multiply the alpha channel, repack (xcursorgen). Compositor blur is
    NOT possible for cursors -- the pointer sits on its own (often
    hardware) plane that Hyprland's blur pipeline cannot sample behind.

    No hyprcursor manifest is generated; Hyprland warns and falls back to
    this XCursor theme of the same name, which is the intended path.
  */
  bibata-glass =
    pkgs.runCommand "bibata-modern-classic-glass"
      {
        nativeBuildInputs = with pkgs; [
          xcur2png
          xcursorgen
          imagemagick
        ];
      }
      ''
        src=${pkgs.bibata-cursors}/share/icons/Bibata-Modern-Classic
        dst=$out/share/icons/Bibata-Modern-Classic-Glass
        mkdir -p $dst/cursors work
        cd work
        for f in $src/cursors/*; do
          n=$(basename "$f")
          if [ -L "$f" ]; then
            cp -P "$f" $dst/cursors/
            continue
          fi
          mkdir "$n.d"
          xcur2png -c "$n.conf" -d "$PWD/$n.d" "$f" > /dev/null
          for p in "$n.d"/*.png; do
            magick "$p" -channel A -evaluate Multiply ${alpha} +channel "$p"
          done
          xcursorgen "$n.conf" "$dst/cursors/$n"
        done
        sed 's/^Name=.*/Name=Bibata-Modern-Classic-Glass/' \
          $src/index.theme > $dst/index.theme
      '';
in
lib.mkIf osConfig.my.cursor-theme.enable {
  /*
    Enforce the cursor across every lookup path an app might use instead
    of the session env (so nothing renders a different theme):
      - sessionVariables XCURSOR_THEME/SIZE (HM sets these from this)
      - gtk.enable: dconf org.gnome.desktop.interface cursor-theme for
        GTK/gsettings readers
      - x11.enable: ~/.icons/default/index.theme Inherits= so even apps
        that ask for the "default" theme land here
    Hyprland's own env block (features/hyprland/home.nix) sets the same theme
    for the compositor renderer and everything it spawns.
  */
  home.pointerCursor = {
    enable = true;
    package = bibata-glass;
    name = "Bibata-Modern-Classic-Glass";
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };

  /*
    pointerCursor.gtk.enable alone is a no-op here: it only sets
    gtk.cursorTheme, which generates nothing while the HM gtk module is
    disabled (DMS owns the gtk.css files), and this HM version never
    touches dconf. GTK under Wayland resolves the cursor from the
    org.gnome.desktop.interface gsettings keys, so without these, pgtk
    apps (emacs daemon) fell back to Adwaita.
  */
  dconf.settings."org/gnome/desktop/interface" = {
    cursor-theme = "Bibata-Modern-Classic-Glass";
    cursor-size = 24;
    # DMS's own `theme = "dark"` (settings.nix) only drives its QML shell and,
    # via qt-theming.nix, Qt/KDE apps -- it never touches this key. GTK apps
    # (Firefox included, via the XDG desktop portal under Wayland) check this
    # gsetting specifically to decide prefers-color-scheme; left unset, GTK's
    # own default is light regardless of what DMS is set to.
    color-scheme = "prefer-dark";
  };

  /*
    xdg-desktop-portal-gtk added at the NixOS level (session-services.nix,
    xdg.portal.extraPortals) lands in /run/current-system/sw/share -- but
    confirmed by running xdg-desktop-portal manually with verbose logging
    (`XDP: load portals from /etc/profiles/per-user/r0k0r/share/xdg-desktop-portal/portals`,
    only hyprland.portal loaded, then `XDP: Requested gtk.portal is
    unrecognized` despite portals.conf correctly saying `default=gtk`): it
    only ever loads portals from ONE directory, the home-manager profile
    (/etc/profiles/per-user/r0k0r/share), not the system one. hyprland.portal
    ends up there because `hyprland` itself (propagating
    xdg-desktop-portal-hyprland) is present in that profile's closure --
    confirmed via `nix-store -q --requisites` on the profile derivation.
    gtk.portal needs to be installed the same way, via home.packages, to
    land in the profile that's actually searched -- the NixOS-level
    extraPortals addition is not wrong, just insufficient on its own.
  */
  home.packages = [ pkgs.xdg-desktop-portal-gtk ];

  # systemd user services (emacs daemon, etc.) don't inherit the Hyprland
  # env block or hm-session-vars; give them the XCursor vars directly.
  systemd.user.sessionVariables = {
    XCURSOR_THEME = "Bibata-Modern-Classic-Glass";
    XCURSOR_SIZE = "24";
  };
}
