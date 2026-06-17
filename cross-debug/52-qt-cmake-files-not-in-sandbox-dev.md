# 52 — Qt cmake files in `out` not accessible in downstream build sandboxes

> **Status: root cause correct; proposed fix was wrong — see [[53-qt-cmake-install-libdir-dev]]**

## Symptom

After applying the `addQtModulePrefix` / `qt-cmake-prefix` fix (doc 50),
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH` is correctly populated at build time:

```
DEBUG QT_ADDITIONAL_PACKAGES_PREFIX_PATH=.../qtbase-...-dev:.../qtbase-...-6.11.0:...
```

cmake still fails:

```
Skipping the build as the condition "TARGET Qt::Quick" is not met.
```

No `-- Found Qt6` message in the cmake log.

## Root Cause

### Nix sandbox restricts access to declared inputs only

The Nix Linux sandbox (bubblewrap) bind-mounts only the paths explicitly listed
in the derivation's `inputDrvs`.  For `qtquick3d` in a cross build:

```
qtdeclarative.drv: ["dev"]
qtbase.drv:        ["dev"]
```

Only the `dev` outputs are in the sandbox.  Qt cmake files live in `$out/lib/cmake/`
(Qt's cmake install rules use `${CMAKE_INSTALL_PREFIX}/lib/cmake/`, where the
prefix is `$out`).  `$out` is invisible to the build.

### Why non-cross builds work

In non-cross builds `getDev` is **not** applied to `propagatedBuildInputs` — the
default output `qtbase.out` lands directly in the downstream sandbox.  `qtbase.out`
has cmake files.  cmake finds `Qt6Config.cmake` there.

In cross builds `getDev` **is** applied, giving `qtbase.dev`.  Inspecting the
store confirms that non-cross `qtbase.dev` contains only `mkspecs/` and
`nix-support/` — no cmake files, no libs.  So cmake finds nothing.

### cmake cannot find Qt6Config.cmake

Setting `CMAKE_PREFIX_PATH` from `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` (which
includes `qtbase.out`) does not help: `qtbase.out` is outside the sandbox and
cmake cannot `stat` any file under it.

## Failed Fix Attempt (do not use)

Copying `$out/lib/cmake` into `$dev/lib/cmake` in `postInstall` breaks
**non-cross** builds.  Qt's `Targets.cmake` files compute `_IMPORT_PREFIX` by
walking four directory levels up from the cmake file's own path:

```cmake
get_filename_component(_IMPORT_PREFIX "${CMAKE_CURRENT_LIST_FILE}" PATH)
... (×4)
```

When the file moves from `$out/lib/cmake/Qt6Foo/` to `$dev/lib/cmake/Qt6Foo/`,
`_IMPORT_PREFIX` changes from `$out` to `$dev`.  Every `IMPORTED_LOCATION`
then references `$dev/lib/libFoo.so.6` — a path that does not exist in `$dev`
(the actual lib is in `$out/lib/`).  cmake's import-file existence check fires:

```
The imported target "Qt6::JsonRpcPrivate" references the file
  ".../qtlanguageserver-6.11.0-dev/lib/libQt6JsonRpc.a"
but this file does not exist.
```

## Correct Fix

See [[53-qt-cmake-install-libdir-dev]]: set `CMAKE_INSTALL_LIBDIR` to
`${placeholder "dev"}/lib` for cross builds so that cmake files **and** their
referenced library files are installed into `$dev` together, keeping
`_IMPORT_PREFIX` correct.

## See also

- [[50-qt-cmake-dev-empty-cross-addQtModulePrefix]] — populate QT_ADDITIONAL_PACKAGES_PREFIX_PATH
- [[53-qt-cmake-install-libdir-dev]] — the working fix
