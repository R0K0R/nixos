# 98 — easyeffects: _qt_additional_packages_prefix_paths invisible in nested find_package scope

## Package
`easyeffects` 8.2.1

## Symptom
Even after setting `QT_ADDITIONAL_PACKAGES_PREFIX_PATH`, cmake still fails:

```
Qt6Graphs could not be found because dependency Qt6Quick could not be found.
```

Qt6Graphs IS found (Qt6Graphs_DIR is set correctly), but its transitive
dependency Qt6Quick isn't.

## Root cause — cmake scoping

`Qt6Config.cmake` calls `__qt_internal_collect_additional_prefix_paths` to
transform `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` into the **local cmake
variable** `_qt_additional_packages_prefix_paths` (a list of `lib/cmake`
paths).

When `Qt6Config.cmake` then calls `find_package(Qt6Graphs)` to load the
component, cmake creates a **new function scope** for
`Qt6GraphsConfig.cmake`.  Local variables from `Qt6Config.cmake`'s scope —
including `_qt_additional_packages_prefix_paths` — are **not visible** in
that nested scope.

`Qt6GraphsDependencies.cmake` calls `_qt_internal_find_qt_dependencies` (a
macro, so it runs in the calling scope) which uses:

```cmake
find_dependency(Qt6Quick ...
    PATHS
        "${CMAKE_CURRENT_LIST_DIR}/.."   # = qtgraphs/lib/cmake
        "${_qt_cmake_dir}"
        ${_qt_additional_packages_prefix_paths}   # ← EMPTY in this scope
)
```

`_qt_additional_packages_prefix_paths` expands to nothing.  Qt6Quick lives in
qtdeclarative (a different store path), so with no PATHS hint cmake can't find
it.

Confirmed by reading:
- `Qt6/Qt6Config.cmake` lines 150–160 (variable is set LOCAL to Qt6Config scope)
- `Qt6/QtPublicCMakeHelpers.cmake` (`__qt_internal_collect_additional_prefix_paths`)
- `Qt6/QtPublicDependencyHelpers.cmake` (`_qt_internal_find_qt_dependencies`)

## Fix
Promote `_qt_additional_packages_prefix_paths` to a **cmake CACHE variable**
via `-D`, making it globally visible in all scopes.
`__qt_internal_collect_additional_prefix_paths` has an early-return guard
(`if(DEFINED "${out_var}") return() endif()`) that sees the cache entry and
skips recomputing, so the cache value takes effect everywhere.

The value must contain the `lib/cmake` sub-paths (what the function would have
produced):

```nix
"-D_qt_additional_packages_prefix_paths=${final.qt6.qtgraphs}/lib/cmake;${final.qt6.qtdeclarative}/lib/cmake;${final.qt6.qtquick3d}/lib/cmake"
```

## Diagnostic
Compare build logs: if Qt6Graphs_DIR shows as found but "Qt6Quick could not
be found" follows, the PATHS passed to find_dependency are empty — this is the
scope issue.
