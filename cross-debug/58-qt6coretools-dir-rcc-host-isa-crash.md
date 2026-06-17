# cross-debug/58: Qt6CoreTools_DIR missing — HOST rcc crashes on build machine

## Problem

In pseudo-cross builds (buildPlatform=x86_64-linux, hostPlatform=x86_64-linux+gcc.arch=meteorlake),
`Qt6::rcc` in cmake custom commands resolves to the **HOST platform** rcc binary.  The HOST rcc
was compiled with `-march=meteorlake` which enables the `waitpkg` ISA extension (Intel-only).
When the build machine is AMD (e.g. Ryzen 9900X / znver5, no waitpkg), any cmake custom command
that calls `Qt6::rcc` aborts at startup:

```
Incompatible processor. This Qt build requires the following features:
    waitpkg
```

Observed in:
- `breeze-icons` HOST build: `Qt6::rcc --binary -o breeze-icons.rcc breeze-icons.qrc`
- `kdoctools` HOST build: `Qt6::rcc` invocations during resource compilation

## Root cause

`Qt6CoreConfig.cmake` (in the HOST platform qtbase) declares a tool dependency on `Qt6CoreTools`:

```cmake
set(__qt_Core_tool_deps "Qt6CoreTools\;6.11.0")
_qt_internal_find_tool_dependencies(...)
```

This calls `find_package(Qt6CoreTools)` to locate native executables (rcc, moc, uic, qlalr).
Without `Qt6CoreTools_DIR` set, cmake's `find_package` searches `CMAKE_PREFIX_PATH`, which in
the pseudo-cross setup contains HOST Qt prefixes.  It finds the HOST platform Qt6CoreTools
and sets `Qt6::rcc` to the HOST rcc (meteorlake-compiled) — which then crashes on AMD.

## Fix

Add `Qt6CoreTools_DIR` pointing to the **BUILD platform** qtbase in cross cmake flags.  The
BUILD platform qtbase ships `lib/cmake/Qt6CoreTools/Qt6CoreToolsConfig.cmake` with the native
(generic x86_64) rcc/moc/uic binaries.

### In `qtModule.nix` (for all Qt HOST module builds):
```nix
++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
  ...
]
```

### In `mk-kde-derivation.nix` (for all KDE HOST package builds):
```nix
++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
  ...
]
```

**IMPORTANT:** In `mk-kde-derivation.nix`, `pkgsBuildBuild` is resolved by callPackage from
the **global** nixpkgs (not the KDE scope splice), so Qt packages are under `pkgsBuildBuild.qt6.*`
(not `pkgsBuildBuild.qtbase` or `pkgsBuildBuild.qtdeclarative`).  See cross-debug/59 for details.

## Relationship to KF6_HOST_TOOLING (breeze-icons)

`breeze-icons` also uses cmake IMPORTED targets for `generate-symbolic-dark` and `qrcAlias`
via `KF6_HOST_TOOLING`.  That mechanism handles those two custom tools, but NOT `Qt6::rcc`.
Setting `Qt6CoreTools_DIR` is required as a complementary fix to cover the rcc case.

See: cross-debug/44 (generate-symbolic-dark), cross-debug/57 (general ISA crash pattern)
