# cross-debug/59: pkgsBuildBuild scope in mk-kde-derivation.nix

## Problem

When adding `pkgsBuildBuild` as a parameter to `mk-kde-derivation.nix` and trying to reference
Qt packages via `pkgsBuildBuild.qtdeclarative`, `pkgsBuildBuild.qtbase`, etc., Nix evaluation
fails with:

```
error: attribute 'qtbase' missing
at .../pkgs/kde/lib/mk-kde-derivation.nix:180:31:
   180|         "-DQt6CoreTools_DIR=${pkgsBuildBuild.qtbase}/lib/cmake/Qt6CoreTools"
```

## Root cause

`mk-kde-derivation.nix` is called via `self.callPackage` in the KDE scope:
```nix
mkKdeDerivation = self.callPackage (import ./lib/mk-kde-derivation.nix self) { };
```

The KDE scope's callPackage resolves arguments from the KDE scope's own attributes first, then
falls back to the **outer (global) nixpkgs `__splicedPackages`**.  The KDE scope does NOT have
`pkgsBuildBuild` as an explicit member.  Therefore, callPackage provides the **global**
`pkgsBuildBuild` (i.e., `pkgs.pkgsBuildBuild`), NOT the KDE scope's BUILD splice
(`pkgsBuildBuild.kdePackages`).

The global `pkgsBuildBuild` does NOT have Qt packages at the top level.  Qt packages are
accessed as `pkgsBuildBuild.qt6.qtbase`, `pkgsBuildBuild.qt6.qtdeclarative`, etc.

This means `pkgsBuildBuild.qtdeclarative` (without `.qt6.`) evaluates to "attribute missing"
even though `pkgsBuildBuild.qt6.qtdeclarative` works fine.

## Verification

```
$ nix eval '.#nixosConfigurations.galaxybook4-pro360.pkgs.pkgsBuildBuild.qtdeclarative.name'
error: does not provide attribute 'pkgsBuildBuild.qtdeclarative'

$ nix eval '.#nixosConfigurations.galaxybook4-pro360.pkgs.pkgsBuildBuild.qt6.qtdeclarative.name'
"qtdeclarative-6.11.0"
```

## Fix

Use `pkgsBuildBuild.qt6.*` for all Qt package references in `mk-kde-derivation.nix`:

```nix
"-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
"-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
"-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
"-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
"-DQt6ScxmlTools_DIR=${pkgsBuildBuild.qt6.qtscxml}/lib/cmake/Qt6ScxmlTools"
"-DQt6RemoteObjectsTools_DIR=${pkgsBuildBuild.qt6.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
```

## Contrast with breeze-icons/kdoctools

In `breeze-icons/default.nix` and `kdoctools/default.nix`, `pkgsBuildBuild` is resolved
by the KDE callPackage AND the code references `pkgsBuildBuild.kdePackages.*` explicitly:
```nix
nativeKdoctools = pkgsBuildBuild.kdePackages.kdoctools.overrideAttrs(...)
```

This is explicitly scoped and works correctly.  The mk-kde-derivation.nix case relies on
the implicit callPackage resolution, which gives the global `pkgsBuildBuild`.

See: cross-debug/58 (Qt6CoreTools_DIR fix that uses these corrected paths)
