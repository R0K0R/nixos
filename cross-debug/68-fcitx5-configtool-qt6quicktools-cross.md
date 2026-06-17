# cross-debug/68: fcitx5-configtool Qt6QuickTools missing in cross builds

## Problem

`fcitx5-configtool-x86_64-unknown-linux-gnu-5.1.13` fails cmake configure:

```
-- Could NOT find Qt6QuickTools (missing: Qt6QuickTools_DIR)
CMake Error at CMakeLists.txt:48 (find_package):
  Found package configuration file:
    .../qtdeclarative-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6Quick/Qt6QuickConfig.cmake
  but it set Qt6Quick_FOUND to FALSE so package "Qt6Quick" is considered to
  be NOT FOUND. Reason given by package:
    Qt6Quick could not be found because dependency Qt6QuickTools could not be found.
```

## Root cause

Same pattern as KDE packages (cross-debug/65): `Qt6QuickConfig.cmake` requires
`Qt6QuickTools` (contains `svgtoqml` and other Quick build tools). In cross
builds, the HOST qtdeclarative cmake config can't find the tools because they
live in the BUILD-platform qtdeclarative, not the HOST one.

Unlike KDE packages (which get the fix via `mk-kde-derivation.nix`),
`fcitx5-configtool` is a standalone `stdenv.mkDerivation` and doesn't benefit
from the shared KDE cmake flag injection.

## Fix

Added to `fcitx5-configtool.nix`:

```nix
{
  pkgsBuildBuild,
  ...
}:
stdenv.mkDerivation {
  cmakeFlags = [
    ...
  ] ++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
  ];
}
```

## Files

- `pkgs/tools/inputmethods/fcitx5/fcitx5-configtool.nix`
