# cross-debug/73: qcoro Qt6Quick component validation fails — QT_ADDITIONAL_PACKAGES_PREFIX_PATH not in cmake cache

## Problem

`qcoro-x86_64-unknown-linux-gnu-0.12.0` cmake configure fails:

```
CMake Error at cmake/QCoroFindQt.cmake:19 (find_package):
  Found package configuration file:
    .../qtbase-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6/Qt6Config.cmake
  but it set Qt6_FOUND to FALSE so package "Qt6" is considered to be NOT FOUND.
  Reason given by package:
  Failed to find required Qt component "Quick".
  Expected Config file at
    ".../qtbase-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6Quick/Qt6QuickConfig.cmake"
  does NOT exist

  Qt6Quick_DIR was computed by CMake or specified on the command line by the user:
    ".../qtdeclarative-x86_64-unknown-linux-gnu-6.11.0/lib/cmake/Qt6Quick"

  The expected and computed paths are different, which might be the reason for
  the package not to be found.
```

## Root cause

`find_package(Qt6 COMPONENTS Quick)` calls into Qt6Config.cmake (shipped by
qtbase). Qt6Config.cmake validates each component by checking whether its cmake
config file lives at the expected path relative to Qt6Config.cmake itself
(i.e., inside qtbase's store path). In nixpkgs, Qt modules live in separate
derivations (`qtdeclarative` for Qt6Quick), so the expected path does not exist.

Qt6Config.cmake has an escape hatch: if `QT_ADDITIONAL_PACKAGES_PREFIX_PATH`
is set as a cmake cache variable, it searches those prefixes during component
validation and accepts components found there.

nixpkgs propagates this via `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` as an
**environment variable**, and `qtModule.nix` contains a `preConfigureHook`
that converts it into a cmake cache variable (or prepends to `CMAKE_PREFIX_PATH`).

**qcoro does not use `qtModule.nix`** — it is an independent cmake library,
not a Qt module. So `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` is set in the
environment but never injected into cmake's cache. Qt6Config.cmake reads it
from the cmake cache, never sees it, and marks Quick as not found.

The issue appeared after our `qtdeclarative` overlay (cross-debug/46, 55)
changed qtdeclarative's derivation hash, invalidating qcoro's cached output
and requiring a fresh build.

## Fix

In `hosts/galaxybook4-pro360/default.nix`, inside the `isMeteorLakeHost`
qt6 `overrideScope`, add a qcoro override that injects the variable directly:

```nix
qcoro = qprev.qcoro.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${qprev.qtdeclarative}"
  ];
});
```

This passes qtdeclarative's store path as a cmake cache variable, satisfying
Qt6Config.cmake's validation for all Quick-dependent components.

## Why qtdeclarative and not the dev output

Qt6Config.cmake searches for components at
`${prefix}/${INSTALL_LIBDIR}/cmake/Qt6${Component}/`. For nixpkgs's qtdeclarative,
the cmake files land in `$out/lib/cmake/Qt6Quick/` (not in `$dev`).
Passing `$out` (which is what `${qprev.qtdeclarative}` evaluates to) is correct.

## Files

- `hosts/galaxybook4-pro360/default.nix` — qcoro cmakeFlags override in qt6 overrideScope
- `pkgs/development/libraries/qt-6/hooks/qtbase-setup-hook.sh` — QT_ADDITIONAL_PACKAGES_PREFIX_PATH env hook
- `pkgs/development/libraries/qt-6/qtModule.nix` — converts env var to cmake for Qt modules
