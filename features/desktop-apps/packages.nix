# GUI applications and the icon/theme packages they resolve against.
{ pkgs }:
let
  lib = pkgs.lib;
  # At this host's fractional DOWNSCALE (primary output scale 0.8), Chromium/Electron apps whose
  # fractional-scale path (WaylandFractionalScaleV1, ON by default) build a physical-sized buffer
  # but fill only the scale-FRACTION of their window -- so they render into the top-left ~0.8 of the
  # frame ("smaller than the screen"). Disabling the feature drops Chromium to integer
  # buffer_scale=1: it renders at the LOGICAL window size and Hyprland downscales the whole window
  # -> full-bleed at any scale. Same fix features/claude-desktop bakes into its own wrapper (see the
  # claude-desktop-fractional-scale note). Two mechanisms, because the launch path differs per app:
  #   - google-chrome has a native `commandLineArgs` hook AND its .desktop Exec is an ABSOLUTE store
  #     path, so a symlinkJoin wrapper would be bypassed -- the .override regenerates both the binary
  #     and the .desktop, so rofi/menu launches pick up the flag.
  #   - discord has no such hook and a PATH-resolved bare `Exec=Discord`, so a thin
  #     symlinkJoin+wrapProgram over its binaries IS what the launcher/rofi resolve and run.
  noFracScale = pkg: bins: pkgs.symlinkJoin {
    name = "${lib.getName pkg}-nofracscale";
    paths = [ pkg ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = lib.concatMapStringsSep "\n"
      (b: ''wrapProgram $out/bin/${b} --add-flags "--disable-features=WaylandFractionalScaleV1"'')
      bins;
  };

  # Storytold "ArtCraft" suite (github.com/storytold) -- open-source, AI-built Rust clones of the
  # Adobe/Office apps. ALL of them (creative + office) are packaged declaratively here, each from its
  # repo's upstream x86_64 AppImage release, wrapped via appimageTools (its own FHS env => runs
  # WITHOUT nix-ld, unlike a bare AppImage -- this host has no nix-ld, see the no-nix-ld note). Every
  # AppImage already ships a correct freedesktop .desktop (Exec=<pname>, which resolves on PATH to the
  # wrapType2 binary) and a full hicolor icon tree, so we extract and re-use those rather than
  # hand-rolling them. EARLY ALPHA -- to update an app: bump its version + re-prefetch the hash
  # (`nix-prefetch-url <release AppImage url>`). Replaces gimp (-> photocraft) and kdenlive
  # (-> filmcraft); installed alongside libreoffice + okular (both kept). See the craft-suite memory.
  # (These were briefly --user flatpaks from the unofficial FlatPark remote; moved fully in-flake.)
  craftApp = { pname, version, hash }:
    let
      src = pkgs.fetchurl {
        url = "https://github.com/storytold/${pname}/releases/download/v${version}/${pname}-${version}-linux-x86_64.AppImage";
        sha256 = hash;
      };
      contents = pkgs.appimageTools.extract { inherit pname version src; };
      # Reuse the AppImage's own .desktop(s) + icons; its Exec is already the bare `${pname}`.
      desktopFiles = pkgs.runCommandLocal "${pname}-${version}-desktop" { } ''
        shopt -s nullglob
        for d in ${contents}/*.desktop; do
          install -Dm644 "$d" "$out/share/applications/$(basename "$d")"
        done
        if [ -d ${contents}/usr/share/icons ]; then
          mkdir -p $out/share
          cp -r ${contents}/usr/share/icons $out/share/
        fi
      '';
    in pkgs.symlinkJoin {
      name = "${pname}-${version}";
      paths = [
        (pkgs.appimageTools.wrapType2 { inherit pname version src; })
        desktopFiles
      ];
    };
in
{
  system = with pkgs; [
    libreoffice
    # --- Storytold "craft" suite: declarative AppImage wraps (see the craftApp note above). ---
    # Creative:
    (craftApp { pname = "photocraft";  version = "0.5.0"; hash = "0byj56czcdl5wknv2yqc650zvls9gvpj9mm0zzybsfq50ww8ckgm"; }) # Photoshop (replaces gimp)
    (craftApp { pname = "filmcraft";   version = "0.4.0"; hash = "0k1dp9b9z12qf4ll86nsvyj3fdfa9f4xv1xd3vg4w1ibggm0shfq"; }) # Premiere (replaces kdenlive)
    (craftApp { pname = "effectcraft"; version = "0.6.0"; hash = "1f70zg0n21badk12k4jxy3yyy24ayqqrd2w0wivfbf01zr72wdcg"; }) # After Effects
    (craftApp { pname = "vectorcraft"; version = "0.7.0"; hash = "0q4bz40mf50j42f2818bampx5lwm58a3pzpb8nhx0fj2vyd8z4pn"; }) # Illustrator
    (craftApp { pname = "lightcraft";  version = "0.4.0"; hash = "0iq8119iwlk5qkswj47zcx1g5w33h2yq9v1hdz8wxq3mdcz9hnh4"; }) # Lightroom
    (craftApp { pname = "designcraft"; version = "0.4.0"; hash = "1gjgqv5xgm5gb7vjcck2hycjd4fxdw5scjn61zabisd7w1cpzlmz"; }) # InDesign/XD
    # Office (alongside libreoffice, which is kept):
    (craftApp { pname = "wordcraft";   version = "0.3.0"; hash = "1v8hswwriw473b00s9lh6r3cg5hhjnv9168600wdkwq7c4k9hmpj"; }) # Word
    (craftApp { pname = "gridcraft";   version = "0.3.0"; hash = "1c9dagqiinvwcizc8l5xfzzwk1xhmy3fw50mkrs4yild8vfkh75f"; }) # Excel
    (craftApp { pname = "deckcraft";   version = "0.3.0"; hash = "1a26c6n98dbpr3byvc0sh3gn4xsbp4kk7wv0p3b5hzhb696mwbyl"; }) # PowerPoint
    rnote
    (google-chrome.override { commandLineArgs = "--disable-features=WaylandFractionalScaleV1"; })
    (noFracScale discord [ "discord" "Discord" ])
    zoom-us
    poppler-utils

    kdePackages.dolphin
    # kdeconnect-kde is installed by programs.kdeconnect, enabled from
    # features/network -- listing it here too would install it independently of
    # the firewall ranges it needs, which is how it came to be half-configured.
    kdePackages.qt6ct
    kdePackages.breeze-icons
    adwaita-icon-theme
    bibata-cursors
  ];
}
