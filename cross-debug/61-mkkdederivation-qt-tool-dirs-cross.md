# cross-debug/61: mk-kde-derivation.nix missing Qt*Tools_DIR in cross builds

## Problem

KDE packages (ki18n, kconfig, kcoreaddons, etc.) that use Qt6::Qml or Qt6::Quick fail in
pseudo-cross builds with:

```
-- Could NOT find Qt6QmlTools (missing: Qt6QmlTools_DIR)
Qt6Qml could not be found because dependency Qt6QmlTools could not be found.
-- Could NOT find Qt6Quick (missing: Qt6Quick_DIR)
```

Or cmake configure fails silently, leaving no `install` target, so ninja reports:
```
ninja: error: unknown target 'install'
```

Observed in: ki18n, and any KDE package that transitively uses Qt6Qml/Qt6Quick.

## Root cause

`mkKdeDerivation` (in `pkgs/kde/lib/mk-kde-derivation.nix`) had no cross-compilation cmake
flags for Qt tool packages.  `Qt6QmlConfig.cmake`, `Qt6QuickConfig.cmake`,
`Qt6ShaderToolsConfig.cmake`, `Qt6ScxmlConfig.cmake`, `Qt6RemoteObjectsConfig.cmake` each
declare tool dependencies via `_qt_internal_find_tool_dependencies`.  Without `*Tools_DIR`
pointing to BUILD platform packages, cmake marks Qt6Qml/Qt6Quick/etc. as NOT FOUND.

## Fix

Added `pkgsBuildBuild` parameter to `mk-kde-derivation.nix` and added cross cmake flags
for all Qt tools packages:

```nix
self:
{
  lib,
  stdenv,
  pkgsBuildBuild,   # <-- added
  makeSetupHook,
  cmake,
  ninja,
  qt6,
  ...
}:
...
cmakeFlags = [ "-DQT_MAJOR_VERSION=6" ]
  ++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    # pkgsBuildBuild is global pkgs.pkgsBuildBuild (not KDE splice) so Qt is under .qt6.*
    "-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
    "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
    "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
    "-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
    "-DQt6ScxmlTools_DIR=${pkgsBuildBuild.qt6.qtscxml}/lib/cmake/Qt6ScxmlTools"
    "-DQt6RemoteObjectsTools_DIR=${pkgsBuildBuild.qt6.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
  ]
  ++ extraCmakeFlags;
```

## Scope gotcha

`pkgsBuildBuild` in `mk-kde-derivation.nix` is the **global** `pkgs.pkgsBuildBuild`, not the
KDE scope splice.  Qt packages are therefore under `pkgsBuildBuild.qt6.*` not directly as
`pkgsBuildBuild.qtdeclarative` etc.  See cross-debug/59 for full analysis.

## Relationship to qtModule.nix

`qtModule.nix` has the same fix for Qt modules themselves (cross-debug/45, 55, 56).
`mk-kde-derivation.nix` needs the same fix for KDE packages that use Qt cmake modules.

See: cross-debug/45, cross-debug/59 (pkgsBuildBuild scope), cross-debug/58 (Qt6CoreTools rcc)
