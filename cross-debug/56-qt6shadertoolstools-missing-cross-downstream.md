# 56 — Qt6ShaderToolsTools not found in cross downstream packages

## Symptom

After fixing [[55-qt6quicktools-missing-cross-downstream]] so downstream cross Qt packages
find `Qt6QuickTools` and `Qt6QmlTools`, `qt5compat` and `qtquick3d` (and others depending
on `Qt::ShaderTools`) still fail:

**qt5compat** (cmake generate step):
```
CMake Error at .../QtTargetHelpers.cmake:192 (target_link_libraries):
  Target "qtgraphicaleffectsprivate" links to:
    Qt6::ShaderTools
  but the target was not found.
```

**qtquick3d** (cmake configure step, hard error):
```
CMake Error at CMakeLists.txt:48 (find_package):
  Could not find a package configuration file provided by
  "Qt6ShaderToolsTools" (requested version 6.11.0) with any of the following
  names:
    Qt6ShaderToolsToolsConfig.cmake
    qt6shadertoolstools-config.cmake
```

Both have `Qt6ShaderTools` under "OPTIONAL packages not found":
```
-- The following OPTIONAL packages have not been found:
 * Qt6ShaderToolsTools (required version >= 6.11.0)
 * Qt6ShaderTools (required version >= 6.11.0)
```

## Root Cause

`Qt6ShaderToolsDependencies.cmake` (installed with HOST `qtshadertools`) declares:

```cmake
set(__qt_ShaderTools_tool_deps "Qt6ShaderToolsTools\;6.11.0")
_qt_internal_find_tool_dependencies("ShaderTools" __qt_ShaderTools_tool_deps)
```

This is the exact same pattern as `Qt6QuickTools`/`Qt6QmlTools` from
[[55-qt6quicktools-missing-cross-downstream]]. `_qt_internal_find_tool_dependencies`
searches for `Qt6ShaderToolsTools` in:
- `${CMAKE_CURRENT_LIST_DIR}/..` = HOST qtshadertools `lib/cmake/` — `Qt6ShaderToolsTools` NOT there
- `${_qt_cmake_dir}` = HOST qtbase `lib/cmake/Qt6/` — NOT there
- `${_qt_additional_packages_prefix_paths}` = HOST Qt paths — NOT there

`Qt6ShaderToolsTools` only exists in the **BUILD platform** qtshadertools
(`lib/cmake/Qt6ShaderToolsTools/` — contains the `qsb` tool). The HOST qtshadertools
has only `Qt6ShaderTools`, `Qt6ShaderToolsPrivate`, `Qt6BuildInternals`.

When `Qt6ShaderToolsTools` is not found and `QT_ALLOW_MISSING_TOOLS_PACKAGES` is
not set, `_qt_internal_find_tool_dependencies` sets `Qt6ShaderTools_FOUND = FALSE`,
so `find_package(Qt6ShaderTools)` returns NOT_FOUND, and `Qt6::ShaderTools` is never
imported as a target.

## Fix

In `pkgs/development/libraries/qt-6/qtModule.nix`, add
`-DQt6ShaderToolsTools_DIR` to the cross cmakeFlags block alongside `Qt6QuickTools_DIR`
and `Qt6QmlTools_DIR`:

```nix
++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
  "-DCMAKE_INSTALL_LIBDIR=${placeholder "dev"}/lib"
  "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
  "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
  "-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
]
```

Setting `Qt6ShaderToolsTools_DIR` cmake cache variable tells cmake exactly where the
config file is, bypassing all search paths. Only the tools cmake config is loaded
(containing the `qsb` tool target), without contaminating general cmake search with
BUILD platform library configs.

## Why no circular evaluation

`lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [...]`:
- HOST cross builds: condition TRUE → `pkgsBuildBuild.qt6.qtshadertools` thunk forced ✓
- BUILD platform builds (pkgsBuildBuild): `buildPlatform == hostPlatform` →
  condition FALSE → thunk never forced → no circular evaluation ✓

## Files Changed

- `pkgs/development/libraries/qt-6/qtModule.nix` — add `-DQt6ShaderToolsTools_DIR` to
  cross cmakeFlags block

## Packages Fixed

All cross Qt packages that depend on `Qt::ShaderTools` (directly or via QML plugins):
- `qt5compat`, `qtquick3d`, `qtgraphs`, `qtmultimedia`, and any other cross Qt module
  that uses `qt_internal_add_qml_module` on plugins linking to `Qt6::ShaderTools`

## Pattern Summary (all three tool dep fixes)

| Tool package | Lives in | Fixed in |
|---|---|---|
| `Qt6ShaderToolsTools` | BUILD `qtshadertools` | `qtModule.nix` cross flags |
| `Qt6QmlTools` | BUILD `qtdeclarative` | `qtModule.nix` cross flags |
| `Qt6QuickTools` | BUILD `qtdeclarative` | `qtModule.nix` cross flags |

## See also

- [[55-qt6quicktools-missing-cross-downstream]] — Qt6QuickTools and Qt6QmlTools fix
- [[54-qtdeclarative-qt6shadertoolstools-dir-typo]] — qtdeclarative-specific fix
