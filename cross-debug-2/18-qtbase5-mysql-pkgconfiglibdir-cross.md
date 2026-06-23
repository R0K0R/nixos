# 18 — qtbase5: MySQL detection fails in cross builds (`PKG_CONFIG_LIBDIR` misuse)

## Symptom

```
MySql .................................. no
ERROR: Feature 'sql-mysql' was enabled, but the pre-condition 'libs.mysql' failed.
```

## Root cause

Qt5's cross configure sets `PKG_CONFIG_LIBDIR` to the pkg-config wrapper's own
binary directory:

```
PKG_CONFIG_LIBDIR=/nix/store/.../pkg-config-wrapper-0.29.2/lib
```

`PKG_CONFIG_LIBDIR`, when set, **completely overrides** `PKG_CONFIG_PATH` —
pkg-config ignores all other search paths and only looks in `PKG_CONFIG_LIBDIR`.
The wrapper binary directory contains no `.pc` files, so pkg-config finds nothing
for any library that isn't explicitly passed via `QMAKE_LIBS_*` / `QMAKE_INCDIR_*`.

Other libraries (dbus, libudev, libpq) work because Qt5's nixpkgs packaging
explicitly passes `QMAKE_LIBS_DBUS`, `QMAKE_LIBS_LIBUDEV`, and `PSQL_LIBS`
env vars, bypassing pkg-config entirely. MySQL has no equivalent bypass.

nixpkgs's qtbase5 defaults `mysqlSupport = true` and passes `-plugin-sql-mysql`
to configure. Qt detects MySQL as absent (pkg-config fails) but errors because
MySQL was explicitly requested.

## Why not a fundamental fix?

The correct fix would be to patch Qt5's configure to not set `PKG_CONFIG_LIBDIR`
incorrectly in cross mode, or to add `MYSQL_LIBS`/`MYSQL_INCDIR` analogous to
`PSQL_LIBS`. However Qt5 reached End of Life in 2020 — no upstream patches are
accepted. A nixpkgs-side patch to Qt5's configure for this obscure cross case is
not worth maintaining.

## Fix

Disable MySQL support in the overlay for this host:

```nix
qt5 = prev.qt5.overrideScope (_qself: qsuper: {
  qtbase = qsuper.qtbase.override { mysqlSupport = false; };
});
```

Note: `mysqlSupport` is a derivation **parameter**, not an attribute — use
`.override { }` (passes to the function), not `.overrideAttrs` (modifies the
resulting derivation).

## Where fixed

`/home/r0k0r/flakes/nixos/hosts/galaxybook4-pro360/default.nix` (overlay)

## Cross-debug category

**Qt5 EOL cross configure bug.** `PKG_CONFIG_LIBDIR` override breaks all
pkg-config detection in cross mode. Other libraries are masked by explicit
`QMAKE_LIBS_*` bypasses; MySQL is not. Fix: disable the feature rather than
patch EOL software.
