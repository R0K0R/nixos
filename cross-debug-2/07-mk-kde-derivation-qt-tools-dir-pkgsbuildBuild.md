# mk-kde-derivation: missing Qt *Tools_DIR cross flags + pkgsBuildBuild not in scope

**Commits:** `7ea458427`, `9df0db70e`
**Files:** `pkgs/kde/lib/mk-kde-derivation.nix`, `pkgs/kde/default.nix`

See also: `cross-debug/57-kde-qt-native-tool-isa-crash.md`, `cross-debug/61-mkkdederivation-qt-tool-dirs-cross.md`

## Symptom

KDE packages fail in cross/pseudo-cross with cmake errors like:

```
Could NOT find Qt6CoreTools (missing: Qt6CoreTools_DIR)
Could NOT find Qt6QmlTools (missing: Qt6QmlTools_DIR)
```

Or crash immediately:

```
Incompatible processor. This Qt build requires the following features: waitpkg
```

## Root Cause (two parts)

**Part 1 — missing cmake flags:** `mkKdeDerivation` had no `isCrossOrPseudo` binding
and no Qt `*Tools_DIR` cmake cache variables. Every KDE package using
`mkKdeDerivation` was therefore missing the flags needed to redirect cmake away from
HOST Qt tools (which crash on AMD) toward BUILD-platform Qt tools.

**Part 2 — pkgsBuildBuild not in scope:** `mk-kde-derivation.nix` did not declare
`pkgsBuildBuild` in its function arguments. The KDE `callPackage` scope (built from
`qt6Packages // frameworks // gear // plasma`) does not contain `pkgsBuildBuild`, so
it could not be auto-filled. Result: `undefined variable 'pkgsBuildBuild'` at eval.

## Fix

**`pkgs/kde/lib/mk-kde-derivation.nix`** — add `pkgsBuildBuild` to function args
and add cross cmake flags:

```nix
self:
{
  lib,
  stdenv,
  ...
  pkgsBuildBuild,   # new
  jq,
}:
let
  isCrossOrPseudo =
    (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform;
in
{
  ...
  cmakeFlags = [ "-DQT_MAJOR_VERSION=6" ]
    ++ lib.optionals isCrossOrPseudo [
      "-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
      "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
      "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
      "-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
      "-DQt6ScxmlTools_DIR=${pkgsBuildBuild.qt6.qtscxml}/lib/cmake/Qt6ScxmlTools"
      "-DQt6RemoteObjectsTools_DIR=${pkgsBuildBuild.qt6.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
      "-DQt6Quick3DTools_DIR=${pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
    ]
    ++ extraCmakeFlags;
```

**`pkgs/kde/default.nix`** — thread `pkgsBuildBuild` from outer pkgs and pass
explicitly to `mkKdeDerivation`:

```nix
{
  ...
  pkgsBuildBuild,   # new: from outer pkgs scope via callPackage auto-fill
  ...
}:
...
mkKdeDerivation = self.callPackage (import ./lib/mk-kde-derivation.nix self) { inherit pkgsBuildBuild; };
```

`pkgsBuildBuild` comes from the outer pkgs scope (it is a standard nixpkgs attribute).
The KDE internal scope doesn't expose it, so it must be passed explicitly via
`{ inherit pkgsBuildBuild; }` rather than relying on `callPackage` auto-fill.
