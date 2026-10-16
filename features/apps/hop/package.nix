/*
  HOP (Open HWP) -- HWP/HWPX document editor, BUILT FROM SOURCE.

  WHY NOT THE .deb ANY MORE. This used to repackage upstream's release .deb,
  which is far cheaper: no toolchain, no dependency vendoring, no hashes to
  chase. That stopped being possible once we needed a patched rhwp.

  The patch is TypeScript in rhwp-studio, compiled by vite into the studio
  bundle, and a HOP release embeds that bundle INSIDE the binary. The installed
  .deb payload is eight files -- one ELF plus a .desktop, a mime XML and four
  icons -- with no .js, .html or .wasm anywhere to patch. Rebuilding is the only
  way to get the fix in. (Measured: the fix cuts sampled CPU while typing from
  11.0s to 3.4s on a machine with ~3700 local fonts. See the rhwp branch.)

  The vendored rhwp_bg.wasm is used exactly as upstream shipped it. The patches
  are pure TypeScript, so wasm-pack is NOT part of this build.

  TAURI v2, NOT ELECTRON -- the shape of the runtime deps below follows from
  that. The binary links the SYSTEM WebKitGTK (libwebkit2gtk-4.1,
  libjavascriptcoregtk-4.1, libsoup-3, gtk-3) rather than bundling a browser,
  which is why the release is 31 MB and not 150.
*/
{
  lib,
  stdenv,
  rustPlatform,
  runCommand,

  cargo-tauri,
  jq,
  moreutils,
  nodejs,
  pkg-config,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  wrapGAppsHook3,

  cairo,
  gdk-pixbuf,
  glib,
  glib-networking,
  gtk3,
  libsoup_3,
  librsvg,
  openssl,
  webkitgtk_4_1,

  # from features/hop/flake.nix: hop source, patched rhwp source, and the
  # version read out of hop's own package.json
  hopSrc,
  rhwpSrc,
  version,
}:

let
  /*
    rhwp is a git SUBMODULE of hop, and GitHub source tarballs do not contain
    submodules -- third_party/rhwp arrives empty. Both the pnpm and cargo
    fetchers need the assembled tree: vite aliases `@` at
    third_party/rhwp/rhwp-studio/src, and apps/desktop/src-tauri/Cargo.lock has
    a path dependency reaching into it. So the tree is composed once, here, and
    used as `src` everywhere below.
  */
  composedSrc = runCommand "hop-${version}-src" { } ''
    cp -r ${hopSrc} $out
    chmod -R u+w $out
    rm -rf $out/third_party/rhwp
    cp -r ${rhwpSrc} $out/third_party/rhwp
    chmod -R u+w $out/third_party/rhwp
  '';
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "hop";
  inherit version;
  src = composedSrc;

  __structuredAttrs = true;
  strictDeps = true;

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-MSyqiVJ3hpihz+x4g2A6WMzG4GShk3AY4aBQDnqh8ME=";
  };

  cargoRoot = "apps/desktop/src-tauri";
  buildAndTestSubdir = finalAttrs.cargoRoot;
  cargoHash = "sha256-pQAqEV9d19oLqeldwr+1RK3XJ3EtUQLkaKW21JTji7Y=";

  # NOTE: these are BASH comments, not Nix ones. A /* ... */ block here is a
  # glob that expands to /bin /boot /dev ... and bash then tries to run /bin.
  postPatch = ''
    # beforeBuildCommand runs `pnpm run build:before-tauri`, which is
    # build:studio plus a macOS QuickLook step. The hook builds the frontend
    # itself (see preBuild), and the QuickLook step cannot run here, so the
    # whole thing is dropped rather than worked around.
    #
    # The updater is removed too: it checks latest.json on every launch and its
    # linux-x86_64-deb target would download a .deb, which does nothing useful
    # on NixOS. Removing the endpoints stops the check rather than letting it
    # fail quietly.
    jq '
      del(.build.beforeBuildCommand) |
      .bundle.createUpdaterArtifacts = false |
      (.plugins.updater.endpoints? // empty) |= []
    ' apps/desktop/src-tauri/tauri.conf.json | sponge apps/desktop/src-tauri/tauri.conf.json
  '';

  nativeBuildInputs = [
    cargo-tauri.hook
    jq
    moreutils
    nodejs
    pkg-config
    pnpmConfigHook
    pnpm_10
    wrapGAppsHook3
  ];

  /*
    librsvg and glib-networking are NOT linked -- they are dlopened, so
    autoPatchelf cannot see them. They are here for wrapGAppsHook3: librsvg
    supplies the gdk-pixbuf SVG loader (the icon themes this config uses are
    SVG), and glib-networking supplies the GIO TLS backend libsoup needs.
    Both fail silently when absent, which is why they are pinned rather than
    left to whatever the ambient profile happens to provide.
  */
  buildInputs = [
    cairo
    gdk-pixbuf
    glib
    glib-networking
    gtk3
    libsoup_3
    librsvg
    openssl
    webkitgtk_4_1
  ];

  # tauri-build embeds frontendDist at compile time, and beforeBuildCommand was
  # stripped above, so the studio bundle has to exist before cargo runs.
  preBuild = ''
    pnpm run build:studio
  '';

  postInstall = ''
    # Two upstream Linux-only bugs, both silent, both carried over from the
    # .deb packaging -- see git history for the full diagnosis.
    #
    # 1. `Exec=hop-desktop` has no field code, so a file manager opening a
    #    document by association passes the path nowhere. The binary does
    #    consume argv (tauri-plugin-single-instance forwards it over D-Bus), so
    #    %F is the whole fix. %F rather than %U: there is no URI handling, and a
    #    file:// string would arrive verbatim and fail to open.
    #
    # 2. .hwpx is not a known type in shared-mime-info, so the desktop file
    #    advertises a type no glob can produce and .hwpx associates with
    #    nothing. The missing definition ships here; NixOS's xdg.mime module
    #    runs update-mime-database over share/mime/packages.
    desktop=$out/share/applications/HOP.desktop
    if [ -f "$desktop" ]; then
      substituteInPlace "$desktop" \
        --replace-fail 'Exec=hop-desktop' "Exec=$out/bin/hop-desktop %F"
    fi
    install -Dm444 ${./hwpx-mime.xml} $out/share/mime/packages/hop-hwpx.xml
  '';

  meta = {
    description = "Open desktop editor for HWP and HWPX documents";
    longDescription = ''
      HOP (Open HWP) opens, edits, saves and exports HWP/HWPX documents -- the
      native formats of Hancom's Korean word processor -- built on the rhwp
      parsing engine. Built from source against a patched rhwp carrying font
      substitution caches.
    '';
    homepage = "https://github.com/golbin/hop";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "hop-desktop";
  };
})
