# cc-wrapper: NIX_CXXFLAGS_COMPILE_BEFORE (C++-only extraBefore variable)

**Commit:** `030dce97b`
**Files:** `pkgs/build-support/cc-wrapper/add-flags.sh`, `pkgs/build-support/cc-wrapper/cc-wrapper.sh`

## Problem

`NIX_CFLAGS_COMPILE_BEFORE` injects flags into `extraBefore` for ALL C and C++
compilations. When used to prepend C++ system header directories
(`-isystem .../c++/15.2.0/`), those directories also appear in C compilations.

GCC 15 ships `c++/15.2.0/stdatomic.h` — a C++23 wrapper header. In C mode,
`__cpp_lib_stdatomic_h` is undefined so the wrapper body is empty, but the
`_GLIBCXX_STDATOMIC_H` include guard fires. This silently shadows the real C11
`<stdatomic.h>`, breaking any C file that uses `memory_order_relaxed` or similar
atomics (e.g. `forkfd_c11.h` in qtbase).

## Fix

New variable `NIX_CXXFLAGS_COMPILE_BEFORE` that only activates when `isCxx=1`.

`add-flags.sh` — add to mangle list so it gets role-suffix treatment:
```bash
var_templates_list=(
    NIX_CFLAGS_COMPILE
    NIX_CFLAGS_COMPILE_BEFORE
    NIX_CXXFLAGS_COMPILE_BEFORE    # new
    ...
)
```

`cc-wrapper.sh` — inject after the existing `extraBefore` line:
```bash
extraBefore=(... $NIX_CFLAGS_COMPILE_BEFORE_@suffixSalt@)
if [[ "$isCxx" = 1 ]]; then
    extraBefore+=($NIX_CXXFLAGS_COMPILE_BEFORE_@suffixSalt@)
fi
```

The `@suffixSalt@` substitution gives it the same role-separation as all other
`NIX_*` variables, so the C++ flags appear only in the C++ cc-wrapper.
