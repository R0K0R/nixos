# 55 — Qt cross downstream packages: Qt6QuickTools not found, Qt::Quick not met

## Symptom

After fixing [[54-qtdeclarative-qt6shadertoolstools-dir-typo]] so `qtdeclarative`
cross builds include `Qt6Quick` cmake files, downstream cross packages still fail:

```
-- Could NOT find Qt6QuickTools (missing: Qt6QuickTools_DIR)
Qt6Quick could not be found because dependency Qt6QuickTools could not be found
Skipping the build as the condition "TARGET Qt::Quick" is not met.
```

The cmake files are now present in `qtdeclarative.out/lib/cmake/Qt6Quick/`, but
loading `Qt6QuickConfig.cmake` fails because it has a hard tool dependency on
`Qt6QuickTools`.

## Root Cause

### Qt's tool dependency mechanism

`Qt6QuickDependencies.cmake` (installed with HOST `qtdeclarative`) declares:

```cmake
set(__qt_Quick_tool_deps "Qt6QuickTools\;6.11.0")
_qt_internal_find_tool_dependencies("Quick" __qt_Quick_tool_deps)
```

`_qt_internal_find_tool_dependencies` in `QtPublicDependencyHelpers.cmake` calls:

```cmake
find_package(Qt6QuickTools
    PATHS
        "${CMAKE_CURRENT_LIST_DIR}/.."
        "${_qt_cmake_dir}"
        ${_qt_additional_packages_prefix_paths}
)
if (NOT Qt6QuickTools_FOUND AND NOT QT_ALLOW_MISSING_TOOLS_PACKAGES)
    set(Qt6Quick_FOUND FALSE)
    return()
endif()
```

`Qt6QmlDependencies.cmake` has the same pattern for `Qt6QmlTools`.

### Qt6QuickTools and Qt6QmlTools live only in BUILD platform qtdeclarative

`Qt6QuickTools` and `Qt6QmlTools` cmake configs contain native tool targets
(`Qt6::qmlcachegen`, `Qt6::qmltc`, etc.). Qt only installs them in the
BUILD platform's qtdeclarative, not the HOST (cross) one.

`CMAKE_CURRENT_LIST_DIR/..` = HOST `qtdeclarative.out/lib/` — no `Qt6QuickTools` there.
`_qt_cmake_dir` = HOST `qtbase.out/lib/cmake/Qt6/` — not there either.
`_qt_additional_packages_prefix_paths` = HOST Qt paths from setup hook — not there.

cmake cannot find `Qt6QuickTools` → `Qt6Quick_FOUND = FALSE` → "Skipping the build".

### The `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` dead-end (failed attempt)

Adding BUILD platform qtdeclarative to `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` in
`preConfigure` does make `Qt6QuickTools` findable, but it also puts BUILD platform
library cmake configs (`Qt6Qml`, `Qt6Quick`, etc.) into the search path. This
causes cmake to load `Qt6QmlBuildInternals.cmake` from the BUILD platform
qtdeclarative instead of the HOST one, breaking packages like `qt5compat`:

```
Target "qtgraphicaleffectsprivate" links to Qt6::ShaderTools but the target was not found.
```

The BUILD platform cmake macros assume BUILD platform Qt components are all present,
but HOST platform targets like `Qt6::ShaderTools` are not defined in that context.

## Fix

In `pkgs/development/libraries/qt-6/qtModule.nix`, add explicit `Qt6QuickTools_DIR`
and `Qt6QmlTools_DIR` cmake flags for cross builds. Setting `<Package>_DIR`
directly tells cmake exactly where to find the config file, bypassing all search
paths. This targets only the tool packages without contaminating the general
cmake search with BUILD platform library configs.

```nix
{
  lib,
  stdenv,
  pkgsBuildBuild,   # ← added
  ...
}:
args:
stdenv.mkDerivation (args // {
  ...
  cmakeFlags = [ ... ]
  ++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    "-DCMAKE_INSTALL_LIBDIR=${placeholder "dev"}/lib"
    # Qt6QuickConfig.cmake and Qt6QmlConfig.cmake declare tool_deps on
    # Qt6QuickTools and Qt6QmlTools. These only exist in the BUILD platform
    # qtdeclarative (native executables: qmlcachegen, qmltc).
    # Setting *_DIR directly bypasses cmake search and avoids contaminating
    # QT_ADDITIONAL_PACKAGES_PREFIX_PATH with BUILD platform library configs.
    "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
    "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
  ]
  ++ args.cmakeFlags or [];
```

### Why explicit `_DIR` flags don't cause pollution

cmake's `find_package(Qt6QuickTools)` checks `Qt6QuickTools_DIR` first (cmake
cache variable). If set, cmake reads `Qt6QuickToolsConfig.cmake` from that
specific directory and does NOT search `CMAKE_PREFIX_PATH`. Only the tools cmake
config is loaded — not the BUILD platform's library configs (`Qt6Qml`,
`Qt6Quick`, etc.).

### Why no circular evaluation for pkgsBuildBuild builds

```nix
lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "...${pkgsBuildBuild.qt6.qtdeclarative}..."
]
```

- HOST cross builds: condition TRUE → string forced → BUILD platform qtdeclarative
  store path embedded ✓
- BUILD platform builds (pkgsBuildBuild): `buildPlatform == hostPlatform` →
  condition FALSE → Nix lazy evaluation never forces the `pkgsBuildBuild.qt6.qtdeclarative`
  thunk → no circular evaluation ✓

## Files Changed

- `pkgs/development/libraries/qt-6/qtModule.nix` — add `pkgsBuildBuild` arg;
  add `-DQt6QuickTools_DIR` and `-DQt6QmlTools_DIR` to cross cmakeFlags

## Packages Fixed

All cross Qt packages that depend on `Qt::Quick` or `Qt::Qml`:
- `qtquick3d`, `qtdatavis3d`, `qtquicktimeline`, `qtlocation`, `qtscxml`,
  `qtgraphs`, `qtremoteobjects`, `qtmultimedia`, `qt3d`, `qtspeech`, `pyside6`,
  `qt5compat`, and any other downstream cross Qt module

## See also

- [[54-qtdeclarative-qt6shadertoolstools-dir-typo]] — why qtdeclarative now has Qt6Quick
- [[50-qt-cmake-dev-empty-cross-addQtModulePrefix]] — QT_ADDITIONAL_PACKAGES_PREFIX_PATH mechanism
- [[52-qt-cmake-files-not-in-sandbox-dev]] — sandbox accessibility via qt-cmake-prefix
