{ config, lib, pkgs, osConfig, ... }:

let
  inScope = import ../../lib/in-scope.nix { inherit osConfig config; feature = "desktop-apps"; };
in
lib.mkIf (osConfig.my.desktop-apps.enable && inScope) {
  /*
    The KDE portal in the HOME profile, so the file-picker routing set in
    features/session-services (FileChooser -> kde) actually resolves.

    xdg-desktop-portal only ever loads .portal files from ONE directory --
    the home-manager profile's share/xdg-desktop-portal/portals -- not the
    system one, which is why features/cursor-theme also puts
    xdg-desktop-portal-gtk here rather than relying on extraPortals alone.
    Without this, kde.portal lands only in /run/current-system/sw/share, the
    daemon never sees it, and the FileChooser route silently falls back to
    gtk. Paired with the extraPortals + config entry on the NixOS side.
  */
  home.packages = [ pkgs.kdePackages.xdg-desktop-portal-kde ];

  /*
    Dolphin's Information panel on by default, giving a live preview of the
    selected file (image, PDF first page, text, video thumbnail) -- the
    closest Dolphin gets to macOS Quick Look, which it has no spacebar
    equivalent for.

    SEEDED, not linked, and in two files because Dolphin splits them:
      dolphinrc          the panel's CONTENT settings ([InformationPanel]).
      dolphinstaterc     the panel's VISIBILITY, a base64 Qt window-state
                         blob under [State]State=. The value below is that
                         blob with infoDock's visible-flag byte flipped and a
                         300px width given to it and its dock area.

    Both are rewritten by Dolphin on almost every action, so a store symlink
    would be clobbered into a dangling link on the next launch (the qt6ct /
    kdeglobals lesson in features/qt-theming). Instead each is written ONCE,
    only when absent -- after that the files are the user's: hide the panel
    and it stays hidden. entryAfter writeBoundary because this touches $HOME.
  */
  home.activation.dolphinPreviewPanel = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    cfg="${config.xdg.configHome}/dolphinrc"
    state="${config.xdg.stateHome}/dolphinstaterc"

    if [ ! -e "$cfg" ]; then
      run mkdir -p "$(dirname "$cfg")"
      run printf '%s\n' '[InformationPanel]' 'previewsShown=true' 'AutoPlayMedia=true' > "$cfg"
    elif ! grep -q '^\[InformationPanel\]' "$cfg"; then
      run printf '\n%s\n' '[InformationPanel]' 'previewsShown=true' 'AutoPlayMedia=true' >> "$cfg"
    fi

    if [ ! -e "$state" ]; then
      run mkdir -p "$(dirname "$state")"
      run printf '%s\n' '[State]' \
        'State=AAAA/wAAAAD9AAAAAwAAAAAAAAC7AAAD0/wCAAAAAvsAAAAWAGYAbwBsAGQAZQByAHMARABvAGMAawAAAAAA/////wAAAAAA////+wAAABQAcABsAGEAYwBlAHMARABvAGMAawEAAAAlAAAD0wAAAEQA////AAAAAQAAASwAAABE/AIAAAAB+wAAABAAaQBuAGYAbwBEAG8AYwBrAQAAACUAAAEsAAAARAD///8AAAADAAAAAAAAAAD8AQAAAAH7AAAAGAB0AGUAcgBtAGkAbgBhAGwARABvAGMAawAAAAAA/////wAAAAAA////AAAC+QAAA9MAAAAEAAAABAAAAAgAAAAI/AAAAAEAAAACAAAAAQAAABYAbQBhAGkAbgBUAG8AbwBsAEIAYQByAQAAAAD/////AAAAAAAAAAA=' \
        > "$state"
    fi
  '';
}
