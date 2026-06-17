# fcitx5: cmake stdlib.h include ordering (same root cause as qtbase, doc 32)

**Package:** `fcitx5-x86_64-unknown-linux-gnu-5.1.19`
**File:** `pkgs/by-name/fc/fcitx5/package.nix`

## Symptom

```
/nix/store/…-x86_64-unknown-linux-gnu-gcc-15.2.0/include/c++/15.2.0/cstdlib:83:15:
  fatal error: stdlib.h: No such file or directory
   83 | #include_next <stdlib.h>
```

## Root Cause

Identical to qtbase issue (doc 32).  cmake, when cross-compiling, queries the cross
compiler for its implicit include directories (`-E -v /dev/null`) and re-emits them as
explicit `-isystem` flags in the generated build.ninja files.  The glibc include dir
(`${stdenv.cc.libc.dev}/include`) is re-emitted BEFORE the C++ standard library headers,
so `#include_next <stdlib.h>` from within GCC's `<cstdlib>` cannot find the C `stdlib.h`
(which comes after glibc in the compiler's built-in path order, but the `-isystem` flag
placed it first, meaning it was already consumed by the time `#include_next` runs).

## Fix

Add a `postConfigure` hook that strips the glibc `-isystem` from all generated ninja
files after cmake configure, same as the qtbase fix:

```nix
postConfigure = lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
  find . -name '*.ninja' | xargs sed -i \
    's| -isystem ${stdenv.cc.libc.dev}/include||g'
'';
```

Applied to `pkgs/by-name/fc/fcitx5/package.nix`.

## Notes

- The same fix is needed for every cmake package that cross-compiles with this
  pseudo-cross setup.  Currently known affected: qtbase, fcitx5.
- See doc 32 for the full root-cause analysis.
