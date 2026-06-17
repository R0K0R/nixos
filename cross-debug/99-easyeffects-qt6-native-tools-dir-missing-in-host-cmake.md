# 99 — easyeffects: Qt6QmlTools/Qt6QuickTools/Qt6Quick3DTools not found (native tools in wrong prefix)

## Package
`easyeffects` 8.2.1

## Symptom
After fixes 97+98, cmake now finds Qt6Quick but immediately fails again:

```
Could NOT find Qt6QmlTools (missing: Qt6QmlTools_DIR)
Qt6Qml could not be found because dependency Qt6QmlTools could not be found.

Could NOT find Qt6QuickTools (missing: Qt6QuickTools_DIR)
Qt6Quick could not be found because dependency Qt6QuickTools could not be found.
```

## Root cause
`Qt6QuickDependencies.cmake` and `Qt6QmlDependencies.cmake` call
`_qt_internal_find_tool_dependencies` for their build-time code-generation
tools.  This macro searches:

```cmake
find_package(Qt6QuickTools ...
    PATHS
        "${CMAKE_CURRENT_LIST_DIR}/.."   # = HOST qtdeclarative/lib/cmake
        "${_qt_cmake_dir}"               # = qtbase/lib/cmake
        ${_qt_additional_packages_prefix_paths}
)
```

`Qt6QuickTools` and `Qt6QmlTools` live in the **native** (BUILD-platform)
qtdeclarative, not the HOST qtdeclarative.  The HOST qtdeclarative at
`fyhr8l…-qtdeclarative-x86_64-unknown-linux-gnu-6.11.0` contains
`Qt6Quick/` and `Qt6Qml/` but NOT `Qt6QuickTools/` or `Qt6QmlTools/`.

The native package at `vyayar14…-qtdeclarative-6.11.0` (no cpu-arch suffix)
contains both `Qt6QmlTools/` and `Qt6QuickTools/`.

Similarly, `Qt6Quick3DDependencies.cmake` needs `Qt6Quick3DTools` which lives
in native qtquick3d (`hm1pbm9…-qtquick3d-6.11.0`).

`Qt6QuickShapes` (also a Qt6Graphs dependency) has no tool deps — no fix needed.
`Qt6Quick3DRuntimeRender` — no tool deps either.

## Fix
Set `*Tools_DIR` cmake cache variables pointing directly to the native
packages.  cmake cache vars bypass all PATHS searching:

```nix
nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
  final.pkgsBuildBuild.qt6.qtdeclarative
  final.pkgsBuildBuild.qt6.qtquick3d
];
cmakeFlags = (old.cmakeFlags or [ ]) ++ [
  "-DQt6QmlTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
  "-DQt6QuickTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
  "-DQt6Quick3DTools_DIR=${final.pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
];
```

`nativeBuildInputs` ensures the native packages are in the build sandbox so
cmake can verify the binaries exist.

## Diagnostic
In the build log, "missing: Qt6QuickTools_DIR" with no path shown means cmake
found Qt6Quick's config file but the tool dependency was not found via any
PATHS.  Check that the native qtdeclarative store path is not the HOST one
(native has no `x86_64-unknown-linux-gnu` in the name).
