# 45 — Qt modules: `Qt6XxxTools` cmake packages not found in pseudo-cross

## Symptom pattern

Any host-platform Qt module (or KDE package depending on one) that has its own
cmake "tools" sub-package fails during cmake configuration:

```
-- Searching for tool 'Qt6::qscxmlc' in package Qt6ScxmlTools.
-- Could NOT find Qt6ScxmlTools (missing: Qt6ScxmlTools_DIR)
CMake Error at .../QtToolHelpers.cmake:1025 (message):
  Failed to find the host tool "Qt6::qscxmlc".  It is part of the
  Qt6ScxmlTools package, but the package could not be found.
```

```
-- Qt6Qml could not be found because dependency Qt6QmlTools could not be found.
```

## Root cause

Qt cmake splits tool executables into separate cmake packages: `Qt6QmlTools`
(qmltyperegistrar, qmlimportscanner, …), `Qt6ScxmlTools` (qscxmlc),
`Qt6ShaderToolsTools` (qsb), `Qt6RemoteObjectsTools` (repc), etc.

Qt's `_qt_internal_find_tool_dependencies` (called by `qt_internal_find_tool`,
`qt_internal_add_tool`, etc.) searches for these packages via `find_package`.

In a proper Qt cross-compilation setup, `QT_HOST_PATH` points to the native
Qt installation prefix; cmake then searches `${QT_HOST_PATH}/lib/cmake/` and
finds all the native tool packages there.

In nixpkgs pseudo-cross:
- `NIXPKGS_CMAKE_PREFIX_PATH` is set by the qtbase setup hook, but it only
  includes HOST (offset 0) packages — not native (offset -1, build-platform) ones.
- `QT_HOST_PATH` is not set (there is no single native Qt prefix in the Nix store;
  each module lives in its own store path).
- The HOST cross-compiled qt module's cmake dir does NOT contain the tool executables
  (they were skipped or patched out during the cross build).
- Result: `find_package(Qt6XxxTools)` searches only host cmake paths, finds nothing.

## Affected Qt modules (non-exhaustive)

| Qt module        | Tools package         | Tool binary     |
|------------------|-----------------------|-----------------|
| qtdeclarative    | Qt6QmlTools           | qmltyperegistrar, qmlimportscanner, qmllint |
| qtscxml          | Qt6ScxmlTools         | qscxmlc         |
| qtshadertools    | Qt6ShaderToolsTools   | qsb             |
| qttools          | Qt6Tools              | many            |
| qtremoteobjects  | Qt6RemoteObjectsTools | repc            |

Any package that calls `qt_internal_add_tool` or uses
`_qt_internal_find_tool_dependencies` for a module in the above list will fail.
This includes both Qt modules themselves and KDE frameworks that depend on them.

## Fix per package

For each failing module, in the nixpkgs overlay:
1. Add the native (pkgsBuildBuild) version of the module to `nativeBuildInputs`
   so Nix includes it in the sandbox and copies it to remote builders.
2. Pass `-DQt6XxxTools_DIR=${nativeModule}/lib/cmake/Qt6XxxTools` in cmakeFlags.

**Critical**: Qt modules (qtdeclarative, qtscxml, qtshadertools, etc.) live in
the `qt6` scope in nixpkgs, NOT in `qt6Packages`. `qt6Packages` is a separate
application wrapper scope. Override `qt6` and use `pkgsBuildBuild.qt6.${attr}`:
```nix
qt6 = prev.qt6.overrideScope (_qfinal: qprev: { ... });
nativeBuildQt = attr: final.pkgsBuildBuild.qt6.${attr};
```
Targeting `qt6Packages` instead silently has no effect on the Qt module builds.

Example for `ki18n` (depends on qtdeclarative tools):
```nix
kdePackages = prev.kdePackages.overrideScope (_kfinal: kprev: {
  ki18n = kprev.ki18n.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ nativeQtDeclarative ];
    cmakeFlags = (old.cmakeFlags or []) ++ [
      "-DQt6QmlTools_DIR=${nativeQtDeclarative}/lib/cmake/Qt6QmlTools"
    ];
  });
});
```

Example for `qtscxml` itself (needs its own native tools):
```nix
qt6Packages = prev.qt6Packages.overrideScope (_qfinal: qprev: {
  qtscxml = qprev.qtscxml.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ nativeQtScxml ];
    cmakeFlags = (old.cmakeFlags or []) ++ [
      "-DQt6ScxmlTools_DIR=${nativeQtScxml}/lib/cmake/Qt6ScxmlTools"
    ];
  });
});
```

## Systematic fix (long-term)

Set `QT_HOST_PATH` to a `symlinkJoin` of all native Qt packages with cmake dirs:
```nix
nativeQtFull = pkgs.symlinkJoin {
  name = "qt6-native-cmake-dirs";
  paths = with pkgsBuildBuild.qt6Packages; [
    qtbase qtdeclarative qtscxml qtshadertools qttools qtremoteobjects
    # ... all modules with tool packages
  ];
};
# Then in each host Qt package or globally via the setup hook:
# cmakeFlags = [ "-DQT_HOST_PATH=${nativeQtFull}" ];
```

This is how proper cross-compilation of Qt is supposed to work, but it requires
an exhaustive list and the symlinkJoin creates a large derivation to rebuild
whenever any native Qt module changes.

## See also

- [[44-breeze-icons-qrcalias-host-binary-runs-on-builder]] — related: Qt host
  binaries running on the build machine
- [[46-nix-sandbox-cmake-flag-paths-not-copied]] — why nativeBuildInputs is required
  alongside the cmake -D flag
