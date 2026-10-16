{ pkgs }:
{
  system = with pkgs; [
    # Native (BUILD-platform) qtdeclarative: qmlls must run here, not on the
    # tuned HOST platform.
    buildPackages.kdePackages.qtdeclarative.dev

    (writeShellScriptBin "qmlls" ''
      exec ${buildPackages.kdePackages.qtdeclarative}/bin/qmlls "$@"
    '')
  ];
}
