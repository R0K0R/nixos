{ pkgs, ... }:

with pkgs; [
  ffmpeg-full
  rnote
  siril
  blender
  easyeffects
  moonlight-qt

  # GPU / VA-API diagnostics
  libva-utils

  # CPU / power monitoring
  powertop
  s-tui
  (kdePackages.kdenlive.overrideAttrs (prev: {
    nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
    postInstall = (prev.postInstall or "") + ''
      wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
    '';
  }))
]
