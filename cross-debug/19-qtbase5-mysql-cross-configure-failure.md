# `qtbase-5.15.18`: MySQL Configure Probe Fails in Cross Build

**Package:** `qtbase-x86_64-unknown-linux-gnu-5.15.18`
**File:** `pkgs/development/libraries/qt-5/modules/qtbase.nix`

## Symptom

```
ERROR: Feature 'sql-mysql' was enabled, but the pre-condition 'libs.mysql' failed.
```

Build exits with code 3 during Qt5 configure phase.

## Root Cause

`mysqlSupport ? true` is unconditionally true. When `mysqlSupport = true`:
- `libmysqlclient` is added to both `buildInputs` (HOST) and `nativeBuildInputs` (BUILD)
- Qt's configure script probes for the MySQL client library
- In a cross build, the probe fails — the configure test compiles and checks
  libraries for the wrong platform, or the cross-prefixed include/lib paths
  are not set up correctly for the Qt qmake-based configure system

`libmysqlclient` in `nativeBuildInputs` is architecturally wrong for cross builds
(it's a library, not a build tool), but the immediate failure is the configure probe
asserting that `libs.mysql` is available when it isn't properly found in the cross environment.

## Fix

```nix
mysqlSupport ? (stdenv.buildPlatform == stdenv.hostPlatform),
```

This disables MySQL support by default in cross builds (where platforms differ even if ISA
is compatible, as in pseudo-cross meteorlake builds). Native builds are unaffected.

The configure flag changes from `-plugin-sql-mysql` to `-no-sql-mysql` in cross builds.

## Note on `nativeBuildInputs`

`libmysqlclient` should not be in `nativeBuildInputs` at all — it is a host library,
not a build tool. In a native build this is harmless. In a cross build the correct
fix would be to remove it from `nativeBuildInputs`. However, disabling `mysqlSupport`
entirely for cross builds is simpler and avoids the probe failure entirely.
