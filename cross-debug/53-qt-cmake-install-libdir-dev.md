# 53 — Qt cross builds: redirect CMAKE_INSTALL_LIBDIR to `dev` so cmake files and libs are sandbox-accessible

> **Status: approach is INEFFECTIVE — Qt's `QtBuildInternalsExtra.cmake` FORCE-overrides `INSTALL_LIBDIR` back to `"lib"` (line 190), then `QtBuildPathsHelpers.cmake` resets `CMAKE_INSTALL_LIBDIR`. The flag in `qtModule.nix` is harmless but does nothing. See [[54-qtdeclarative-qt6shadertoolstools-dir-typo]] for the actual root cause and fix.**

## Problem recap

In cross builds, nixpkgs applies `getDev` to `propagatedBuildInputs`, so
downstream build sandboxes contain only the `dev` outputs of Qt dependencies.
Qt cmake files land in `$out/lib/cmake/` (via `CMAKE_INSTALL_LIBDIR = $out/lib`
set by nixpkgs's cmake multi-output hook).  `$out` is not in the sandbox.
cmake cannot find `Qt6Config.cmake` and all modules that depend on `Qt::Quick`,
`Qt::Qml`, etc. fail at configure time.

See [[52-qt-cmake-files-not-in-sandbox-dev]] for why copying cmake files from
`$out` to `$dev` in `postInstall` is wrong (it breaks `_IMPORT_PREFIX`
computation and causes `IMPORTED_LOCATION` existence checks to fail for
non-cross builds).

## Root Cause Summary

| | Non-cross | Cross |
|-|-----------|-------|
| `getDev` applied to deps? | No — `qtbase.out` in sandbox | Yes — only `qtbase.dev` in sandbox |
| cmake files location | `$out/lib/cmake/` | `$out/lib/cmake/` |
| `qtbase.dev` contents | `mkspecs/` + `nix-support/` only | same — empty |
| cmake can find Qt6Config.cmake? | ✓ (out is in sandbox) | ✗ (out not in sandbox) |

## Fix

In `pkgs/development/libraries/qt-6/qtModule.nix`, append
`-DCMAKE_INSTALL_LIBDIR` to `cmakeFlags` for cross builds:

```nix
cmakeFlags = [
  "--log-level=STATUS"
  "-DCMAKE_SYSTEM_VERSION="
]
++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "-DCMAKE_INSTALL_LIBDIR=${placeholder "dev"}/lib"
]
++ lib.optionals stdenv.hostPlatform.isDarwin [ ... ]
++ args.cmakeFlags or [];
```

### Why this works

`CMAKE_INSTALL_LIBDIR` controls where Qt installs:
- shared libraries (`.so`, `.so.6`, `.so.6.x.y`)
- static libraries (`.a`)
- cmake config files (`lib/cmake/Qt6Foo/`)
- `.prl` files

With `LIBDIR = $dev/lib`, all of these land in `$dev`.  Downstream cross builds
have `$dev` in their sandbox.  When cmake loads `$dev/lib/cmake/Qt6/Qt6Config.cmake`:

- `_IMPORT_PREFIX` is computed four levels up from the cmake file → `$dev` ✓
- `IMPORTED_LOCATION = $dev/lib/libQt6Quick.so.6` — file exists in `$dev` ✓
- cmake's import-existence check passes ✓
- `TARGET Qt::Quick` is defined ✓
- linker finds `-lQt6Quick` via `-L$dev/lib` ✓

### Why it doesn't break non-cross builds

The flag is guarded by `stdenv.buildPlatform != stdenv.hostPlatform`.  In
non-cross builds the condition is false; the flag is not added; `CMAKE_INSTALL_LIBDIR`
remains `$out/lib` (nixpkgs default).  Non-cross behavior is unchanged.

### Override order

nixpkgs's cmake multi-output hook injects `-DCMAKE_INSTALL_LIBDIR=$out/lib`
early in the cmake invocation.  `qtModule.nix`'s `cmakeFlags` are appended
**after** those flags, so the last occurrence of `-DCMAKE_INSTALL_LIBDIR` wins
and our `$dev/lib` value takes effect.

### Runtime library location

Runtime libraries (`.so.6.x.y`) now live in `$dev` instead of `$out` for cross
Qt builds.  This means the runtime closure of cross-built Qt applications
includes `$dev` rather than `$out`.  This is unconventional but functional for
the purpose of building and running the NixOS system.  The `$out` output of
cross Qt modules will contain bins, plugins, metatypes, and share data —
everything that does not go through `CMAKE_INSTALL_LIBDIR`.

## Effect

Triggers a full cascade rebuild of all cross Qt modules:
`qtbase` → `qtdeclarative` → `qtshadertools` → … → `qtquick3d` etc.

## Packages Fixed

- `qtquick3d` — needs `Qt::Quick`
- `qtdatavis3d` — needs `Qt::Quick`
- `qtquicktimeline` — needs `Qt::Quick`
- `qtlocation` — needs `Qt::Qml`
- `qtscxml` — needs `Qt::Qml`
- any other cross Qt module that `find_package`s Qt components

## Files Changed

- `pkgs/development/libraries/qt-6/qtModule.nix` — add
  `-DCMAKE_INSTALL_LIBDIR` for cross builds

## See also

- [[52-qt-cmake-files-not-in-sandbox-dev]] — problem analysis + failed cp approach
- [[50-qt-cmake-dev-empty-cross-addQtModulePrefix]] — earlier layer: QT_ADDITIONAL_PACKAGES_PREFIX_PATH
- [[51-qtremoteobjects-native-repc-tool]] — separate native tool fix for qtremoteobjects
