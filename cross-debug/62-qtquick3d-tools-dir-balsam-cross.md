# cross-debug/62: Qt6Quick3DTools_DIR missing — balsam tool not found

## Problem

`qtquick3d-x86_64-unknown-linux-gnu` fails cmake configure with exit code 1:

```
-- Searching for tool 'Qt6::balsam' in package Qt6Quick3DTools.
-- Could NOT find Qt6Quick3DTools (missing: Qt6Quick3DTools_DIR)
CMake Error at .../Qt6/QtToolHelpers.cmake:1025 (message):
  Failed to find the host tool "Qt6::balsam".  It is part of the
  Qt6Quick3DTools package, but the package could not be found.  Make sure you
  have built and installed the host Quick3D module, which will ensure the
  creation of the Qt6Quick3DTools package.
```

Cascade failures: qtmultimedia, qtspeech depend on qtquick3d and fail with
"Build failed due to failed dependency".

## Root cause

Same pattern as Qt6ScxmlTools_DIR (cross-debug/55), Qt6RemoteObjectsTools_DIR, etc.
`Qt6Quick3DConfig.cmake` declares a tool dependency on `Qt6Quick3DTools` via
`_qt_internal_find_tool_dependencies`.  Without `Qt6Quick3DTools_DIR` pointing to the
BUILD platform package, cmake cannot find `balsam` and fails.

## Fix

Added to both `qtModule.nix` and `mk-kde-derivation.nix`:

```nix
"-DQt6Quick3DTools_DIR=${pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
```

Files:
- `pkgs/development/libraries/qt-6/qtModule.nix`
- `pkgs/kde/lib/mk-kde-derivation.nix`

## Pattern

Every Qt module that ships tools (executables used at build time by downstream
consumers) needs a `Qt6<Module>Tools_DIR` cross flag.  Modules confirmed so far:

| Module         | Tools package          | Key tools             |
|----------------|------------------------|-----------------------|
| qtbase         | Qt6CoreTools           | rcc, moc, uic         |
| qtdeclarative  | Qt6QmlTools            | qmlimportscanner      |
| qtdeclarative  | Qt6QuickTools          | quicktestmain         |
| qtshadertools  | Qt6ShaderToolsTools    | qsb                   |
| qtscxml        | Qt6ScxmlTools          | qscxmlc               |
| qtremoteobjects| Qt6RemoteObjectsTools  | repc                  |
| qtquick3d      | Qt6Quick3DTools        | balsam                |

See: cross-debug/58 (Qt6CoreTools pattern), cross-debug/45 (original discovery)
