# qtwebengine: gn version mismatch + PKG_CONFIG_HOST in cross builds

**Pattern:** F14 (cmake try_run / find_package version check in cross) + F4-adjacent (PKG_CONFIG_HOST)
**Fix:** `qt6Gn` derivation (Qt-patched gn) in nixpkgs-contrib + `preConfigure` PKG_CONFIG_HOST

## Symptom 1: gn version mismatch

```
CMake Error at src/CMakeLists.txt:90 (message):
  No gn found for cross-compilation
```

`configure.cmake` calls:
```cmake
find_package(Gn ${QT_REPO_MODULE_VERSION} EXACT)  # requires "6.11.0" exactly
```

`FindGn.cmake` runs `gn --version` → system gn reports `"2341 (d8c2f07d6535)"`.
Qt-patched regex `([1-9]\.[0-9]\.[0-9])\.qtwebengine\.qt\.io.*` doesn't match
→ version stays "2341" → `Gn_FOUND=FALSE`.

`src/CMakeLists.txt` lines 89-91:
```cmake
if(CMAKE_CROSSCOMPILING AND NOT Gn_FOUND)
   message(FATAL_ERROR "No gn found for cross-compilation")
endif()
```

In native builds, `CMAKE_CROSSCOMPILING=FALSE` so this check is skipped and
qtwebengine falls through to `ExternalProject_Add(gn ...)` which builds gn
from `src/3rdparty/gn/` using `gen.py --qt-version 6.11.0.qtwebengine.qt.io`.
In cross mode, `CMAKE_CROSSCOMPILING=TRUE` → FATAL_ERROR.

There is a second FATAL_ERROR at lines 119-120 (hostBuild ExternalProject_Add):
```cmake
if(CMAKE_CROSSCOMPILING AND NOT IOS AND NOT MACOS AND NOT WIN32)
    if(NOT Gn_FOUND)
        message(FATAL_ERROR "\nHost gn not found - cross compilation not possible")
    endif()
```

## Fix for Symptom 1

Add `qt6Gn` to the Qt6 scope in nixpkgs (`pkgs/development/libraries/qt-6/qt6-gn.nix`).
This derivation builds gn from the same qtwebengine source using `gen.py` directly:

```bash
python3 src/3rdparty/gn/build/gen.py \
    --qt-version "6.11.0.qtwebengine.qt.io" \
    --out-path gn-build ...
ninja -C gn-build gn
```

The resulting binary reports `"6.11.0.qtwebengine.qt.io"` which matches the
Qt version regex → `Gn_VERSION="6.11.0"` → `find_package(Gn 6.11.0 EXACT)` passes
→ `Gn_FOUND=TRUE` → both FATAL_ERRORs are skipped (their condition `NOT Gn_FOUND` is FALSE).

In qtwebengine's `nativeBuildInputs`, use `buildPackages.qt6.qt6Gn` instead of
system `gn` when `!stdenv.buildPlatform.canExecute stdenv.hostPlatform`.
The BUILD-side `qt6Gn` binary is in PATH before the cmake configure phase, so
`find_program(Gn_EXECUTABLE NAMES gn)` in `FindGn.cmake` finds it.

## Symptom 2: PKG_CONFIG_HOST_EXECUTABLE not found

```
Could NOT find PkgConfigHost (missing: PKG_CONFIG_HOST_EXECUTABLE)
```

`cmake/FindPkgConfigHost.cmake`:
```cmake
if(CMAKE_CROSSCOMPILING)
   if((NOT PKG_CONFIG_HOST_EXECUTABLE) AND (NOT "$ENV{PKG_CONFIG_HOST}" STREQUAL ""))
       set(PKG_CONFIG_HOST_EXECUTABLE "$ENV{PKG_CONFIG_HOST}" ...)
   endif()
   find_program(PKG_CONFIG_HOST_EXECUTABLE NAMES "pkg-config" ...
       NO_SYSTEM_ENVIRONMENT_PATH   ← skips PATH
       NO_CMAKE_FIND_ROOT_PATH
   )
```

In pseudo-cross PATH only has `x86_64-unknown-linux-gnu-pkg-config` (prefixed),
not plain `pkg-config`. `NO_SYSTEM_ENVIRONMENT_PATH` prevents PATH search.

The cmake code DOES check `$ENV{PKG_CONFIG_HOST}` first and uses it as a cache
variable (which persists past the subsequent `find_program`). 

## Fix for Symptom 2

In `qtwebengine/default.nix`, add `preConfigure` to set `PKG_CONFIG_HOST`:

```nix
preConfigure =
  lib.optionalString (!(stdenv.buildPlatform.canExecute stdenv.hostPlatform)) ''
    _hostPkgConfig=$(command -v "${stdenv.hostPlatform.config}-pkg-config" 2>/dev/null || true)
    if [ -n "$_hostPkgConfig" ]; then
      export PKG_CONFIG_HOST="$_hostPkgConfig"
    fi
  ''
  + ''
    export NINJAFLAGS="-j$NIX_BUILD_CORES"
  '';
```

`x86_64-unknown-linux-gnu-pkg-config` is in PATH via NIX_IS_PSEUDO_CROSS=1 / F4 hook.
`command -v` resolves it at build time; cmake sees `$ENV{PKG_CONFIG_HOST}` → sets
`PKG_CONFIG_HOST_EXECUTABLE` in cache → `find_program` with `NO_SYSTEM_ENVIRONMENT_PATH`
is a no-op (variable already cached) → `PkgConfigHost_FOUND=TRUE`.

## Files Modified

- `pkgs/development/libraries/qt-6/qt6-gn.nix` (new) — builds Qt-patched gn
- `pkgs/development/libraries/qt-6/default.nix` — adds `qt6Gn` to Qt6 scope
- `pkgs/development/libraries/qt-6/modules/qtwebengine/default.nix` — uses
  `buildPackages.qt6.qt6Gn` in cross builds + sets `PKG_CONFIG_HOST`

Commit: `05278fded` on branch `pseudo-cross-fundamental`
