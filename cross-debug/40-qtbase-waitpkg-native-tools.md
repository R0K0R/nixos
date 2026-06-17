# qtbase native tools: libQt6Core requires `waitpkg`, crashes on Ryzen build machine

**Package:** `qtbase-6.11.0` (pkgsBuildBuild context — native tools: rcc, qmlimportscanner, …)
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

## Symptom

```
Incompatible processor. This Qt build requires the following features:
    waitpkg
FAILED: [code=134] icons/breeze-icons.qrc …
```

This happens when cmake runs `rcc` (from the native qtbase in the build sandbox) to
process `.qrc` files.  yulee (the remote builder) is a Ryzen 9900X (Zen 5), which is
AMD and does NOT support Intel's `waitpkg` (UMWAIT/UMONITOR) extension.

## Root Cause

Qt 6.11 introduced `qatomicwait.cpp` which uses the `UMWAIT` instruction from the
`waitpkg` extension for efficient spin-wait operations.  The file is compiled as part
of the MAIN `libQt6Core` (not as a runtime-dispatch optional path), and GCC/Clang
adds `__WAITPKG__` to the translation unit's defines when `-mwaitpkg` is in the compile
flags.

In the galaxybook4-pro360 NixOS cross-build context, `pkgsBuildBuild.qt6.qtbase`
(the "native" qtbase used to provide build tools) happens to be compiled with `-mwaitpkg`
(exact root cause unclear — likely the NixOS overlays cause a different stdenv than plain
nixpkgs for pkgsBuildBuild).  As a result, `libQt6Core.so.6` marks `waitpkg` as a
REQUIRED CPU feature, and any tool linked against it (rcc, qmlimportscanner, …) aborts
immediately on any CPU that lacks `waitpkg`.

The ELF ISA notes only show `x86-64-v4` (AVX512), not `waitpkg` — the requirement comes
from Qt's own runtime `qt_processorFeatureCheck()`, not from the ELF compatibility notes.

## Fix

In `postConfigure` for non-cross builds (`!isCrossBuild`), strip `-mwaitpkg` from all
generated ninja compile commands.  This prevents `qatomicwait.cpp` from being compiled
with the waitpkg extension, so the resulting native tools don't require it at runtime.

```nix
postConfigure = lib.optionalString isCrossBuild ''
  # … existing isystem fix …
'' + lib.optionalString (!isCrossBuild) ''
  # Qt 6.11 compiles qatomicwait.cpp with -mwaitpkg for UMWAIT-based atomic
  # waits, making waitpkg a *required* CPU feature in libQt6Core and all
  # tools that link it (rcc, qmlimportscanner, …). Native build tools must
  # run on the build machine (which may be AMD / lack waitpkg). Strip the
  # flag so the tools work on any x86_64 host.
  find . -name '*.ninja' | xargs sed -i 's/ -mwaitpkg//g'
'';
```

## Notes

- The CROSS qtbase (`qtbase-x86_64-unknown-linux-gnu`) intentionally keeps `waitpkg`
  enabled — it is deployed on the galaxybook4-pro360 (Intel Meteorlake) which supports it.
- `isCrossBuild = !stdenv.buildPlatform.canExecute stdenv.hostPlatform` correctly
  distinguishes native (pkgsBuildBuild) from cross builds.
- The failure manifested via breeze-icons running rcc from the native qtbase.
