# cross-debug/74: qcoro Qt6Quick cmake validation fails — Qt6QuickTools_DIR missing

## Problem

After fixing cross-debug/73 (QT_ADDITIONAL_PACKAGES_PREFIX_PATH), qcoro cmake configure
still fails:

```
-- Could NOT find Qt6QuickTools (missing: Qt6QuickTools_DIR)
CMake Warning at .../Qt6Config.cmake:246 (find_package):
  Found package configuration file:
    .../qtdeclarative-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6Quick/Qt6QuickConfig.cmake
  but it set Qt6Quick_FOUND to FALSE so package "Qt6Quick" is considered to be NOT FOUND.
  Reason given by package:
  Qt6Quick could not be found because dependency Qt6QuickTools could not be found.
```

## Root cause

After `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` is set, Qt6Config.cmake finds
`Qt6QuickConfig.cmake` in `qtdeclarative`'s store path.  But `Qt6QuickConfig.cmake`
calls `find_dependency(Qt6QuickTools)` — the cmake config for the native Quick tools
(svgtoqml, etc.).  `Qt6QuickTools` lives in the **native** (build-platform)
`qtdeclarative`, not the host one.

The cmake variable `Qt6QuickTools_DIR` points to the native qtdeclarative cmake dir.
This is set in `mkKdeDerivation` for KDE packages but not for `qt6Packages.qcoro`
(which uses a plain cmake derivation).

## Fix

In `hosts/galaxybook4-pro360/default.nix`, in the qcoro override inside
`qt6Packages.overrideScope`, add both the native qtdeclarative as a
`nativeBuildInput` and its cmake dir as a flag:

```nix
qcoro = qpprev.qcoro.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    final.pkgsBuildBuild.qt6.qtdeclarative
  ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${final.qt6.qtdeclarative}"
    "-DQt6QuickTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
  ];
});
```

Adding the native qtdeclarative to `nativeBuildInputs` ensures the cmake config
files are accessible in the sandbox.

## Relationship to cross-debug/73

cross-debug/73 fixed the first layer (QT_ADDITIONAL_PACKAGES_PREFIX_PATH reaching
cmake's cache).  This issue is the second layer: Qt6Quick's own cmake config has a
hard `find_dependency(Qt6QuickTools)` that also needs the native cmake dir.

## Files

- `hosts/galaxybook4-pro360/default.nix` — qcoro overlay in qt6Packages.overrideScope
