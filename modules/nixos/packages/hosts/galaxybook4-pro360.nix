{ pkgs, inputs, ... }:

with pkgs;
[

  buildPackages.kdePackages.qtdeclarative.dev

  (writeShellScriptBin "qmlls" ''
    exec ${buildPackages.kdePackages.qtdeclarative}/bin/qmlls "$@"
  '')

  (kdePackages.kdenlive.overrideAttrs (prev: {
    nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ [ makeBinaryWrapper ];
    postInstall = (prev.postInstall or "") + ''
      wrapProgram $out/bin/kdenlive --prefix LADSPA_PATH : ${rnnoise-plugin}/lib/ladspa
    '';
  }))
]
