# 42: KDE frameworks fail with "mismatched Qt dependencies" in pseudo-cross

## Error
```
Error: detected mismatched Qt dependencies:
    /nix/store/q7612...-qtbase-x86_64-unknown-linux-gnu-6.11.0   ← host
    /nix/store/74gxn...-qtbase-6.11.0                            ← native/build
```
Seen in: karchive, kcodecs, kconfig, kdbusaddons, kglobalaccel, ki18n, kitemviews,
kirigami, solid, sonnet, kwindowsystem and others built via mk-kde-derivation.nix.

## Root cause
`qtbase-setup-hook.sh` uses a single global `__nix_qtbase` variable to detect
duplicate/conflicting Qt versions. In a pseudo-cross build:
- `nativeBuildInputs = [ qt6.wrapQtAppsHook ]` gets spliced to the BUILD-platform
  Qt6, whose setup hook runs with `hostOffset=-1` and sets `__nix_qtbase` to the
  NATIVE qtbase path.
- `buildInputs = [ qt6.qtbase ]` then runs its hook with `hostOffset=0` (HOST Qt),
  finds `__nix_qtbase` already set to the native path → mismatch → exit 1.

The native and host Qt are actually DIFFERENT platforms of the same version (both
6.11.0), so it's correct to have both. The check was not offset-aware.

## Fix
`pkgs/development/libraries/qt-6/hooks/qtbase-setup-hook.sh`

1. Replace `__nix_qtbase` with a per-offset variable `__nix_qtbase_at_${hostOffset}`.
   Mismatch is only an error if the SAME offset sees two different qtbase paths.
2. When `hostOffset != 0` (native/build-platform Qt), return early after recording
   the path — skipping the QMAKE, wrapQtApps, postPatchMkspecs setup which is only
   meaningful for the host Qt.

## Also fixed in same build
- shiboken6: added `-DQFP_PYTHON_HOST_PATH` (shiboken6's cross-build API for the
  build-machine Python; `libshiboken/CMakeLists.txt` uses this when
  `SHIBOKEN_IS_CROSS_BUILD=TRUE`, not `Python_EXECUTABLE`)
