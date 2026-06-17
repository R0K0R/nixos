# 51 — qtremoteobjects: `repc` (Qt6RemoteObjectsTools) not found in pseudo-cross

## Symptom

```
CMake Error at qtremoteobjects/Qt6RemoteObjectsToolsConfig.cmake:...
  Could NOT find Qt6RemoteObjectsTools (missing: Qt6RemoteObjectsTools_DIR)
```

`qtremoteobjects` configure fails because `repc` (the Remote Objects Compiler)
is only in the native (build-platform) qtremoteobjects and cmake cannot find it
via the default search paths in a pseudo-cross build.

## Root Cause

Same pattern as `qtscxml` (doc 45): Qt modules that include code-generator tools
ship those tools only in the build-platform variant.  In a pseudo-cross build,
`NIXPKGS_CMAKE_PREFIX_PATH` only contains HOST package paths; native tool cmake
dirs are never added.  `cmake`'s `find_package(Qt6RemoteObjectsTools)` fails.

## Fix

Add `qtremoteobjects` to the `overrideScope` overlay in
`hosts/galaxybook4-pro360/default.nix`, using the existing `addQtNativeTool`
helper pattern:

```nix
qtremoteobjects = addQtNativeTool
  (nativeBuildQt "qtremoteobjects") "Qt6RemoteObjectsTools" qprev.qtremoteobjects;
```

This adds `pkgsBuildBuild.qt6.qtremoteobjects` to `nativeBuildInputs` (so Nix
copies it into the build sandbox) and passes
`-DQt6RemoteObjectsTools_DIR=${nativePkg}/lib/cmake/Qt6RemoteObjectsTools` as
a cmake flag, bypassing the broken auto-discovery.

## See also

- [[45-qt-tool-packages-missing-in-pseudo-cross-cmake]] — general pattern for native Qt tool cmake dirs
- [[48-qt6-scope-overlay-pitfalls]] — overrideScope pitfalls and isMeteorLakeHost guard
