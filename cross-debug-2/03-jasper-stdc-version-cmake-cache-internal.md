# 03 — jasper: cmake cannot auto-detect `__STDC_VERSION__` in cross mode

## Symptom

```
CMake Error at CMakeLists.txt:445 (message):
  The value of __STDC_VERSION__ cannot be automatically determined when
  cross-compiling.  Please set JAS_STDC_VERSION to the value of
  __STDC_VERSION__ when invoking CMake (e.g., by using the option
  -DJAS_STDC_VERSION=...) or modify the CMakeLists.txt appropriately.
```

## Root cause

`jasper/CMakeLists.txt:443` checks whether it's cross-compiling:

```cmake
if((DEFINED JAS_CROSSCOMPILING AND JAS_CROSSCOMPILING) OR
   (NOT DEFINED JAS_CROSSCOMPILING AND CMAKE_CROSSCOMPILING))
    ...
    set(JAS_STDC_VERSION "0L" CACHE INTERNAL "The value of __STDC_VERSION__.")
    if (JAS_STDC_VERSION STREQUAL "0L")
        message(FATAL_ERROR ...)
    endif()
```

`CMAKE_CROSSCOMPILING` is `TRUE` in pseudo-cross (because of the different gcc.arch
target prefix on the cc-wrapper). So jasper enters the cross-compiling branch.

The upstream `jasper/package.nix` handles this for REAL cross with:
```nix
preConfigure = lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
  cmakeFlagsArray+=(-DJAS_STDC_VERSION="$(echo __STDC_VERSION__ | $CXX -E -P -)")
'';
```

In pseudo-cross `buildPlatform.canExecute hostPlatform` is `true` (same ISA), so this
block is skipped — but `CMAKE_CROSSCOMPILING` is still true. The two detection
mechanisms disagree.

## Failed fix: `-DJAS_STDC_VERSION=201710L` via cmakeFlags

First attempt added the flag via `overrideAttrs`:
```nix
cmakeFlags = (old.cmakeFlags or []) ++ [ "-DJAS_STDC_VERSION=201710L" ];
```

This generated a new drv hash (overlay was applied), but the build still failed.

**Why:** cmake's `set(VAR value CACHE INTERNAL doc)` without `FORCE` is documented
to not override existing cache entries. However, in practice with the cmake version
nixpkgs uses, `CACHE INTERNAL` type always writes the sentinel `"0L"`, overriding
the `-D` flag from the command line. The F11 preload mechanism (which generates
`set(JAS_STDC_VERSION "201710L" CACHE STRING "" FORCE)` via `CMAKE_PROJECT_INCLUDE`)
also could not reliably override the subsequent `CACHE INTERNAL` set.

## Fix: postPatch the cmake source

Since cmake cache semantics are unreliable here, the most direct fix is to patch
the sentinel default value in the cmake source:

```nix
jasper = prev.jasper.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace CMakeLists.txt \
      --replace-fail \
        'set(JAS_STDC_VERSION "0L" CACHE INTERNAL "The value of __STDC_VERSION__.")' \
        'set(JAS_STDC_VERSION "201710L" CACHE INTERNAL "The value of __STDC_VERSION__.")'
  '';
});
```

`201710L` = C17 (`__STDC_VERSION__` for C17 standard), which is what GCC 15 compiles
with by default. This is the correct value for jasper 4.x with any modern toolchain.

## Cross-debug category

**Pattern mismatch:** nixpkgs uses `canExecute` to guard the detection path, but cmake
uses `CMAKE_CROSSCOMPILING` (set by the toolchain prefix). These disagree in pseudo-cross.
This is a pseudo-cross-specific issue; real cross and native builds both work fine via
their respective code paths.

A future upstream fix would be: jasper should check `CMAKE_CROSSCOMPILING AND NOT
CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR` (i.e., only skip
detection when binaries can't actually run on the build machine).
