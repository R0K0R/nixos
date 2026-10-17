{ config, lib, pkgs, ... }:

let
  /*
    Storytold "ArtCraft" suite (github.com/storytold) -- open-source, AI-built Rust clones of the
    Adobe/Office apps. ALL of them (creative + office) are packaged declaratively here, each from its
    repo's upstream x86_64 AppImage release, wrapped via appimageTools (its own FHS env => runs
    WITHOUT nix-ld, unlike a bare AppImage -- the desktop has no nix-ld). Every AppImage already
    ships a correct freedesktop .desktop (Exec=<pname>, which resolves on PATH to the wrapType2
    binary) and a full hicolor icon tree, so we extract and re-use those rather than hand-rolling
    them. EARLY ALPHA -- to update an app: bump its version + re-prefetch the hash
    (`nix-prefetch-url <release AppImage url>`). Replaces gimp (-> photocraft) and kdenlive
    (-> filmcraft); installed alongside libreoffice + okular (both kept). (These were briefly --user
    flatpaks from the unofficial FlatPark remote; moved fully into the config.)
  */
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
  options.my.storytold.enable = lib.mkEnableOption
    "the Storytold craft suite (photocraft, filmcraft, effectcraft, vectorcraft, lightcraft, designcraft, wordcraft, gridcraft, deckcraft) as AppImage wraps";

  config = lib.mkIf config.my.storytold.enable {
    home.packages = [
      # Creative:
      (craftApp { pname = "photocraft";  version = "0.5.0"; hash = "0byj56czcdl5wknv2yqc650zvls9gvpj9mm0zzybsfq50ww8ckgm"; }) # Photoshop (replaces gimp)
      (craftApp { pname = "filmcraft";   version = "0.4.0"; hash = "0k1dp9b9z12qf4ll86nsvyj3fdfa9f4xv1xd3vg4w1ibggm0shfq"; }) # Premiere (replaces kdenlive)
      (craftApp { pname = "effectcraft"; version = "0.6.0"; hash = "1f70zg0n21badk12k4jxy3yyy24ayqqrd2w0wivfbf01zr72wdcg"; }) # After Effects
      (craftApp { pname = "vectorcraft"; version = "0.7.0"; hash = "0q4bz40mf50j42f2818bampx5lwm58a3pzpb8nhx0fj2vyd8z4pn"; }) # Illustrator
      (craftApp { pname = "lightcraft";  version = "0.4.0"; hash = "0iq8119iwlk5qkswj47zcx1g5w33h2yq9v1hdz8wxq3mdcz9hnh4"; }) # Lightroom
      (craftApp { pname = "designcraft"; version = "0.4.0"; hash = "1gjgqv5xgm5gb7vjcck2hycjd4fxdw5scjn61zabisd7w1cpzlmz"; }) # InDesign/XD
      # Office (alongside libreoffice, which the system installs):
      (craftApp { pname = "wordcraft";   version = "0.3.0"; hash = "1v8hswwriw473b00s9lh6r3cg5hhjnv9168600wdkwq7c4k9hmpj"; }) # Word
      (craftApp { pname = "gridcraft";   version = "0.3.0"; hash = "1c9dagqiinvwcizc8l5xfzzwk1xhmy3fw50mkrs4yild8vfkh75f"; }) # Excel
      (craftApp { pname = "deckcraft";   version = "0.3.0"; hash = "1a26c6n98dbpr3byvc0sh3gn4xsbp4kk7wv0p3b5hzhb696mwbyl"; }) # PowerPoint
    ];
  };
}
