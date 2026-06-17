# 97 — easyeffects: Qt6Graphs cmake prefix mismatch (qtgraphs in separate store path)

## Package
`easyeffects` 8.2.1

## Symptom
cmake configure fails with:

```
Failed to find required Qt component "Graphs".

Expected Config file at
  ".../qtbase-.../lib/cmake/Qt6Graphs/Qt6GraphsConfig.cmake"
does NOT exist

Qt6Graphs_DIR was computed by CMake:
  ".../qtgraphs-.../lib/cmake/Qt6Graphs"

The expected and computed paths are different
```

## Root cause
In nixpkgs, Qt6 modules live in **separate store paths** (qtbase, qtgraphs,
qtdeclarative, qtquick3d, …).  `Qt6Config.cmake` (from qtbase) uses
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH` to allow components from foreign
prefixes, but without it every component must be under the same store path as
`qtbase`.

`easyeffects` uses `find_package(Qt6 COMPONENTS Graphs)` which goes through
`Qt6Config.cmake`.  In a normal build the nixpkgs cmake setup hooks populate
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH` automatically via the Qt environment
hook; that hook is skipped for non-Qt packages in a pseudo-cross build.

## Fix

```nix
cmakeFlags = (old.cmakeFlags or [ ]) ++ [
  "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${final.qt6.qtgraphs};${final.qt6.qtdeclarative};${final.qt6.qtquick3d}"
];
```

All three extra Qt6 module store paths must be listed because Qt6Graphs
depends on Qt6Quick (qtdeclarative) and Qt6Quick3D (qtquick3d), and
Qt6Config.cmake validates each transitive component's prefix in the same pass.

## See also
73-qcoro-qt6quick-additional-packages-prefix-path.md — same pattern for qcoro.
Next entry (98) covers why this alone is not enough.
