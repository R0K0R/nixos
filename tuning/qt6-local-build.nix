# Qt6 bootstrap runs meteorlake-built tools (waitpkg) during the build; Yulee (AMD) cannot run them.
# kdePackages merges qt6Packages; patching only kdePackages.qtbase misses bootstrap qtbase drvs
# (qttools → qtbase.override { qttranslations = null; }) and leaves other Qt modules on the old qtbase.
{ lib, ... }:
let
  localQt6Drv =
    pkg:
    pkg.overrideAttrs (old: {
      preferLocalBuild = true;
      requiredSystemFeatures = (old.requiredSystemFeatures or [ ]) ++ [ "galaxybook-local-qt6" ];
    });

  patchQt6Bootstrap =
    prevQt6:
    let
      qtbaseBootstrap = localQt6Drv (prevQt6.qtbase.override { qttranslations = null; });
      qttools =
        localQt6Drv (prevQt6.qttools.override {
          qtbase = qtbaseBootstrap;
          qtdeclarative = null;
        });
      qttranslations = localQt6Drv (prevQt6.qttranslations.override { inherit qttools; });
      qtbase = localQt6Drv (prevQt6.qtbase.override { inherit qttranslations; });
    in
    prevQt6.overrideScope (_final: _prev: {
      inherit qtbase qttools qttranslations;
    });

  patchedQt6 =
    prevQt6:
    (patchQt6Bootstrap prevQt6)
    // {
      inherit (prevQt6) override extend recurseForDerivations;
    };
in
{
  nix.settings.system-features = lib.mkAfter [ "galaxybook-local-qt6" ];

  nixpkgs.overlays = lib.mkAfter [
    (final: prev: {
      # overrideScope rebinds qtconnectivity etc.; merge scope ops back (python-packages uses qt6.override).
      qt6 = patchedQt6 prev.qt6;

      # python-packages has its own qt6; pyside6 captures python.pkgs.qt6 at eval (must rebuild pyside6).
      python3Packages =
        let
          qt6' = patchedQt6 prev.python3Packages.qt6;
          pyPkgs = prev.python3Packages // {
            inherit qt6';
            qt6 = qt6';
          };
        in
        pyPkgs
        // {
          pyside6 = pyPkgs.pyside6.override {
            python =
              (prev.python3.override {
                passthru = prev.python3.passthru // {
                  pkgs = pyPkgs;
                };
              });
          };
        };
    })
  ];
}
