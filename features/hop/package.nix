/*
  HOP (Open HWP) -- HWP/HWPX document editor, repackaged from the upstream .deb.

  TAURI v2, NOT ELECTRON. This matters for the whole shape of the file. The deb
  is 31 MB and its payload is one 53 MB ELF linked against the *system*
  WebKitGTK -- libwebkit2gtk-4.1, libjavascriptcoregtk-4.1, libsoup-3, gtk-3 --
  plus a .desktop file and four hicolor PNGs. Nothing else; no bundled Chromium,
  no asar, no node_modules. Verified with `patchelf --print-needed` against the
  shipped binary, not inferred from the README (which says "Electron" and is
  wrong for the Linux target -- the `latest.json` + minisign `.sig` release
  assets and the WebKitGTK dependency are Tauri's updater conventions).

  Hence a dpkg-extract-and-patch job rather than a source build: HOP is a pnpm
  monorepo whose release binary is produced by tauri-bundler, so building it
  would need the pnpm store and network fetches inside the sandbox to arrive at
  a binary already published as a release asset.

  WHY autoPatchelfHook AND NOT the manual patchelf loop ../claude-desktop uses:
  there is exactly one dynamic ELF here, and autoPatchelfHook *fails the build*
  on any NEEDED library it cannot resolve. claude-desktop needs the loop because
  cowork-linux-helper is statically linked and has to be skipped with `|| true`
  -- which also means a genuinely missing library there is a runtime crash
  instead of a build error. With one well-behaved binary, the loud version is
  available, so take it.

  WHY wrapGAppsHook3 AND NOT hand-rolled makeWrapper: this is a real GTK3 app,
  so it wants the standard GTK runtime environment -- GSETTINGS_SCHEMAS_PATH,
  GDK_PIXBUF_MODULE_FILE, GIO_EXTRA_MODULES (glib-networking, for TLS through
  libsoup) and XDG_DATA_DIRS for icon and MIME lookup. The hook derives all of
  those from buildInputs. claude-desktop spells them out by hand because
  Electron needs only the schemas, and that hand-rolled path is where its long
  nativeBuildInputs comment about glib's setup-hook offsets comes from.

  TWO UPSTREAM BUGS ARE FIXED BELOW, both Linux-only oversights consistent with
  a bundler validated on macOS (where file association goes through the app
  bundle's Info.plist and never touches a .desktop file):

    1. `Exec=hop-desktop` carries no field code, so a file manager opening a
       document by association passes the path nowhere and you get an empty
       window. The binary does consume argv -- it links
       tauri-plugin-single-instance 2.4.1, whose Linux implementation forwards
       `argv` over D-Bus to the already-running instance, which is precisely the
       open-this-file-in-the-existing-window path. So `%F` is the fix; the
       binary needs no patching.

    2. `.hwpx` is not a known type anywhere in shared-mime-info 2.4. Its
       freedesktop.org.xml registers application/x-hwp with glob *.hwp and the
       application/vnd.haansoft-hwp alias, and nothing at all for hwpx. The
       desktop file's MimeType=application/vnd.hancom.hwpx therefore named a
       type no glob could ever produce, so .hwpx files never associated with
       anything. The missing definition is shipped here.
*/
{
  lib,
  stdenv,
  dpkg,
  autoPatchelfHook,
  wrapGAppsHook3,
  cairo,
  gdk-pixbuf,
  glib,
  glib-networking,
  gtk3,
  libsoup_3,
  librsvg,
  webkitgtk_4_1,
  # the hop-bin flake input (the raw .deb in the store) and the version beside
  # it, both from features/hop/flake.nix so they cannot drift apart
  src,
  version,
}:
stdenv.mkDerivation {
  pname = "hop";
  inherit src version;

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    wrapGAppsHook3
  ];

  /*
    Exactly the NEEDED set of usr/bin/hop-desktop, resolved:

      libgtk-3.so.0 libgdk-3.so.0            gtk3
      libwebkit2gtk-4.1.so.0
        libjavascriptcoregtk-4.1.so.0        webkitgtk_4_1
      libsoup-3.0.so.0                       libsoup_3
      libgobject-2.0.so.0 libglib-2.0.so.0
        libgio-2.0.so.0                      glib
      libgdk_pixbuf-2.0.so.0                 gdk-pixbuf
      libcairo.so.2                          cairo
      libgcc_s.so.1                          stdenv.cc.cc

    librsvg and glib-networking are NOT in that list -- they are dlopened, and
    so are invisible to autoPatchelfHook. They are here for wrapGAppsHook3 to
    find: librsvg supplies the gdk-pixbuf SVG loader (the icon themes this
    config uses, breeze-dark and Adwaita, are SVG), and glib-networking supplies
    the GIO TLS backend that libsoup needs for the update check. Both fail
    silently when absent, which is exactly why they are pinned in place rather
    than left to whatever the ambient profile happens to provide.
  */
  buildInputs = [
    cairo
    gdk-pixbuf
    glib
    glib-networking
    gtk3
    libsoup_3
    librsvg
    stdenv.cc.cc
    webkitgtk_4_1
  ];

  /*
    GStreamer is deliberately NOT wired up. WebKitGTK prints

      GStreamer element appsink not found. Please install it.

    once at startup and goes on working; it only needs GStreamer to decode
    HTML5 <video>/<audio> inside the webview, and a HWP document editor reaches
    that path only if rhwp renders an embedded media object as an HTML5 element,
    which nothing observed here does. The remedy, if that day comes, is
    gst_all_1.{gstreamer,gst-plugins-base,gst-plugins-good} in buildInputs plus
    a GST_PLUGIN_SYSTEM_PATH_1_0 prefix in the wrapper -- roughly 150 MB of
    closure for it.

    Left out rather than added-just-in-case because the failure is already loud:
    that line names the missing element on every launch. This is the one case
    where "fail loud" is satisfied by upstream's own diagnostic.
  */

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dpkg --fsys-tarfile $src | tar --extract
    mkdir -p $out
    mv usr/* $out

    runHook postInstall
  '';

  postFixup = ''
    # Absolute Exec plus the missing field code. %F (list of local paths) rather
    # than %U: the single-instance plugin forwards raw argv, and the binary has
    # no URI handling -- a file:// string would arrive verbatim and fail to open.
    substituteInPlace $out/share/applications/HOP.desktop \
      --replace-fail 'Exec=hop-desktop' "Exec=$out/bin/hop-desktop %F"

    # The hwpx type shared-mime-info does not define; see the file's own header
    # for why it is glob-only. NixOS's xdg.mime module runs update-mime-database
    # over share/mime/packages from environment.systemPackages, so dropping it
    # here is all that is needed -- no activation script of our own.
    install -Dm444 ${./hwpx-mime.xml} $out/share/mime/packages/hop-hwpx.xml
  '';

  /*
    NO WEBKIT_DISABLE_DMABUF_RENDERER HERE, ON PURPOSE.

    The reflex for a Tauri app on NixOS is to set it: WebKitGTK >=2.42 renders
    through a DMA-BUF pipeline that shows a blank white window on a fair number
    of Wayland/driver combinations, and webkitgtk here is 2.52. It was set in
    the first version of this file for exactly that reason.

    Then it was actually tested, on this machine (Meteor Lake iGPU, Hyprland
    0.56, webkitgtk 2.52.5) by building this derivation with `preFixup = ""` and
    launching it: HOP renders completely -- full Korean UI, toolbar, document
    panel, correct fonts. The variable was doing nothing except disabling the
    faster render path.

    So it is gone. If a blank window ever does appear -- after a webkitgtk bump,
    or on different hardware -- the fix is a preFixup that appends

      gappsWrapperArgs+=(--set-default WEBKIT_DISABLE_DMABUF_RENDERER 1)

    (--set-default, not --set, so it stays overridable from the environment).
    But do not add it back on suspicion. Reproduce the blank window first.
  */

  meta = {
    description = "Open desktop editor for HWP and HWPX documents";
    longDescription = ''
      HOP (Open HWP) opens, edits, saves and exports HWP/HWPX documents -- the
      native formats of Hancom's Korean word processor -- built on the rhwp
      parsing engine. Repackaged from the upstream .deb release asset.
    '';
    homepage = "https://github.com/golbin/hop";
    downloadPage = "https://github.com/golbin/hop/releases";
    # MIT, per the LICENSE file at the repo root. The package is still a
    # prebuilt binary rather than a source build -- see sourceProvenance below;
    # the license covers redistribution either way, so nothing here needs
    # allowUnfree (unlike ../claude-desktop).
    license = lib.licenses.mit;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "hop-desktop";
  };
}
