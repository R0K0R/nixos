{ pkgs, ... }:

let
  # Match the glass system (dolphin/kitty windows sit at 0.65).
  alpha = "0.35";

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
{
  /*
    Enforce the cursor across every lookup path an app might use instead
    of the session env (so nothing renders a different theme):
      - sessionVariables XCURSOR_THEME/SIZE (HM sets these from this)
      - gtk.enable: dconf org.gnome.desktop.interface cursor-theme for
        GTK/gsettings readers
      - x11.enable: ~/.icons/default/index.theme Inherits= so even apps
        that ask for the "default" theme land here
    Hyprland's own env block (wayland/hyprland.nix) sets the same theme
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
  };

  # systemd user services (emacs daemon, etc.) don't inherit the Hyprland
  # env block or hm-session-vars; give them the XCursor vars directly.
  systemd.user.sessionVariables = {
    XCURSOR_THEME = "Bibata-Modern-Classic-Glass";
    XCURSOR_SIZE = "24";
  };
}
