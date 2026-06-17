# Meteorlake laptop + AMD (znver5) remote builder.
#
# Qt packages in nixpkgs use scope-level mkDerivation (signature: { mkDerivation, … }),
# not stdenv.mkDerivation directly. Passing stdenv via .override {stdenv = …} is silently
# ignored — mkDerivation closes over the meteorlake stdenv baked into the scope at
# import time, so the DRV hash never changes and qtwaylandscanner still requires waitpkg.
#
# Fix: import a separate generic x86_64 nixpkgs (no gcc.arch → no -march flag) and
# replace qt6 + kdePackages wholesale. No override surgery needed.
# Rest of the system stays -march=meteorlake.
{ config, lib, inputs, ... }:
let
  genericPkgs = import inputs.nixpkgs {
    inherit (config.nixpkgs) config;
    system = "x86_64-linux";
  };
in
{
  nixpkgs.overlays = lib.mkAfter [
    (_final: _prev: {
      qt6 = genericPkgs.qt6;
      kdePackages = genericPkgs.kdePackages;
    })
  ];
}
