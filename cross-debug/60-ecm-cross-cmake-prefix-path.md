# cross-debug/60: ECM not found in cross builds (fcitx5-gtk, fcitx5-hangul, fcitx5-qt)

## Problem

Non-KDE packages that use `kdePackages.extra-cmake-modules` (ECM) in `nativeBuildInputs` fail
in pseudo-cross builds with:

```
Could not find a package configuration file provided by "ECM" with any of the following names:
    ECMConfig.cmake
    ecm-config.cmake
Add the installation prefix of "ECM" to CMAKE_PREFIX_PATH or set "ECM_DIR"...
```

Observed in:
- `fcitx5-gtk` (uses `kdePackages.extra-cmake-modules`)
- `fcitx5-hangul` (same)
- `fcitx5-qt` (both Qt5 and Qt6 versions)
- Any non-KDE `stdenv.mkDerivation` package with ECM in nativeBuildInputs

## Root cause

The nixpkgs cmake setup hook (`pkgs/by-name/cm/cmake/setup-hook.sh`) adds packages to
`NIXPKGS_CMAKE_PREFIX_PATH` via:

```bash
addEnvHooks "$targetOffset" addCMakeParams
```

`$targetOffset` is the HOST offset (0 for a HOST build's buildInputs).  **BUILD platform
packages in `nativeBuildInputs` are at offset -1 and are NOT added** to
`NIXPKGS_CMAKE_PREFIX_PATH`.

ECM is in `nativeBuildInputs` (BUILD platform), so `ECMConfig.cmake` (at
`share/ECM/cmake/ECMConfig.cmake` in the ECM derivation) is never added to cmake's search
path.  `find_package(ECM REQUIRED)` fails.

## Fix

Add `pkgsBuildBuild` parameter and set `ECM_DIR` explicitly in cross cmake flags for each
affected package:

```nix
{
  lib,
  stdenv,
  pkgsBuildBuild,
  ...
}:
stdenv.mkDerivation {
  ...
  cmakeFlags = [
    ...existing flags...
  ] ++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    "-DECM_DIR=${pkgsBuildBuild.kdePackages.extra-cmake-modules}/share/ECM/cmake"
  ];
}
```

Files fixed:
- `pkgs/by-name/fc/fcitx5-gtk/package.nix`
- `pkgs/by-name/fc/fcitx5-hangul/package.nix`
- `pkgs/tools/inputmethods/fcitx5/fcitx5-qt.nix`

## Notes

- KDE packages (`mkKdeDerivation`) are NOT affected because their cmake config is handled
  by the KDE scope's cmake setup.
- Qt module packages (`qtModule.nix`) are also not affected because ECM is not used there.
- The ECM path within the derivation is `share/ECM/cmake/` (not `lib/cmake/`).
- `pkgsBuildBuild.kdePackages.extra-cmake-modules` is used (not `pkgsBuildBuild.extra-cmake-modules`)
  because ECM is provided as a KDE package.

See: cross-debug/45 (general Qt *Tools_DIR pattern that led to this discovery)
