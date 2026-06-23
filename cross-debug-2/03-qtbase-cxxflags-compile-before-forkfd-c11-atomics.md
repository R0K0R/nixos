# qtbase: NIX_CFLAGS_COMPILE_BEFORE bleeds C++ headers into C, breaks forkfd C11 atomics

**Package:** `qtbase-x86_64-unknown-linux-gnu-6.11.0`
**Commit:** `030dce97b`
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

## Symptom

```
In file included from .../forkfd/forkfd_c11.h:35,
                 from .../forkfd/forkfd.c:90:
/nix/store/...-c++-15.2.0/stdatomic.h:35:2: error: #error "forkfd_c11.h requires <stdatomic.h>"
```

or:

```
forkfd_c11.h:42:37: error: 'memory_order_relaxed' undeclared
```

## Root Cause

The cross-debug/32 fix for `stdlib.h: No such file or directory` used
`env.NIX_CFLAGS_COMPILE_BEFORE` to inject C++ system include dirs:

```nix
env.NIX_CFLAGS_COMPILE_BEFORE =
  lib.optionalString (isCrossOrPseudo)
    "-isystem ${stdenv.cc.cc}/include/c++/...";
```

`NIX_CFLAGS_COMPILE_BEFORE` applies to **all** compilations including C. GCC 15's
`c++/15.2.0/stdatomic.h` is a C++23 wrapper; in C mode it fires its include guard
but defines nothing, shadowing the real C11 `<stdatomic.h>`. Any C file that
includes `<stdatomic.h>` gets an empty header → `memory_order_relaxed` undeclared.

## Fix

Switch to `env.NIX_CXXFLAGS_COMPILE_BEFORE` (new variable from commit `030dce97b`,
see 02-cc-wrapper-nix-cxxflags-compile-before.md) which only activates for C++:

```nix
env.NIX_CXXFLAGS_COMPILE_BEFORE =
  lib.optionalString (isCrossBuild || (stdenv.isPseudoCross or false))
    ("-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}"
    + " -isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}/${stdenv.hostPlatform.config}");
```

C files no longer see the C++ header dirs; the `stdlib.h` fix still works for C++.
