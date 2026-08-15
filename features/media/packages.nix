{ pkgs }:
{
  system = with pkgs; [
    ffmpeg-full
    blender
    moonlight-qt

    # kdenlive needs rnnoise-plugin's LADSPA path wired in explicitly; the
    # plugin is built without LV2 (see tuning/overlays/pseudo-cross.nix, which
    # disables the LV2 helper because it is a HOST-compiled binary the BUILD
    # machine cannot run).
    (kdePackages.kdenlive.overrideAttrs (prev: {
      nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
      postInstall = (prev.postInstall or "") + ''
        wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
      '';
    }))
  ];
}
