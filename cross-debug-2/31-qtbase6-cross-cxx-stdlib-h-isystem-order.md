# 31 — Qt6 qtbase: cross C++ headers `-isystem` order (stdlib.h / c++config.h)

**Package:** `qtbase-x86_64-unknown-linux-gnu-6.11.0`  
**Fix:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`  
**Commits:** `fbbf81253` → `d0b8b6646` → `3faae5c20` → `ae4f068b7` (four iterations)

## Symptom

```
/nix/store/.../x86_64-unknown-linux-gnu-gcc-15.2.0/include/c++/15.2.0/bits/version.h:51:10:
  fatal error: bits/c++config.h: No such file or directory

/nix/store/.../x86_64-unknown-linux-gnu-gcc-15.2.0/include/c++/15.2.0/cstdlib:83:15:
  fatal error: stdlib.h: No such file or directory
```

## Root Cause

The cross GCC's built-in system include search path (no extra flags) is:

```
1. include/c++/15.2.0/           ← C++ generic headers (cstdlib, etc.)
2. include/c++/15.2.0/x86_64-unknown-linux-gnu/  ← bits/c++config.h lives here
3. include/c++/15.2.0/backward/
4. lib/gcc/x86_64-unknown-linux-gnu/15.2.0/include
5. include/
6. lib/gcc/x86_64-unknown-linux-gnu/15.2.0/include-fixed
7. glibc-dev/include              ← stdlib.h lives here (built-in, last)
```

In this order:
- `cstdlib` is found at position 1.
- `#include_next <stdlib.h>` searches 2+, finds glibc's `stdlib.h` at 7. ✓
- `bits/c++config.h` is found at position 2. ✓

**What cmake does:** cmake emits an explicit `-isystem /glibc-dev/include` for
target include directories flagged `SYSTEM`. Explicit `-isystem` entries are
sorted **before** GCC's built-in system includes. This changes the search order:

```
1. glibc-dev/include              ← explicit -isystem (cmake-emitted)
2. include/c++/15.2.0/            ← built-in (now AFTER glibc)
3. include/c++/15.2.0/x86_64-unknown-linux-gnu/
...
  (glibc NOT repeated — GCC deduplicates it with entry 1)
```

Now:
- `cstdlib` found at position 2.
- `#include_next <stdlib.h>` searches 3+: C++ target-specific, backward, compiler
  headers, include-fixed — **no glibc** (deduplicated away). → NOT FOUND ✗
- `bits/c++config.h` search from `version.h` (found at 2) — position 3 has
  `x86_64-unknown-linux-gnu/bits/c++config.h`... but does position 3 exist?
  Only if the explicit `-isystem` didn't fully collapse the built-in list.

The cc-wrapper itself uses `-idirafter` for glibc (see `libc-cflags`). The
cmake-emitted `-isystem` is what promotes glibc above the C++ built-ins.

## Why `-I` doesn't fix it (iteration 3)

Adding `-I .../c++/15.2.0` to `NIX_CFLAGS_COMPILE` appears logical but fails:

```
$ g++ -I.../c++/15.2.0 -isystem /glibc-dev/include -E -v -x c++ /dev/null
warning: ...include/c++/15.2.0: as it is a non-system directory that
         duplicates a system directory
#include <...> search:
  /glibc-dev/include      ← -isystem wins
  include/c++/15.2.0/     ← -I path deduplicated to built-in position
  ...
```

GCC detects that `-I <path>` points to a built-in system directory and silently
deduplicates it: the path stays at its **built-in position**, not promoted to the
user-include position. The warning is the clue.

## Why `NIX_CFLAGS_COMPILE` is too late (iteration 3 continued)

The cc-wrapper processes flags in this order for the final compiler invocation:

```bash
extraBefore=(hardeningCFlagsBefore NIX_CFLAGS_COMPILE_BEFORE_<suffix>)  # ← before cmake
params=(cmake's command-line flags)                                        # ← cmake -isystem glibc here
extraAfter=(hardeningCFlagsAfter NIX_CFLAGS_COMPILE_<suffix>)            # ← after cmake
```

`NIX_CFLAGS_COMPILE` maps to `extraAfter` — placed **after** cmake's `-isystem
glibc`. Even if `-I` worked, it would come after glibc in the invocation order.

## The `NIX_CFLAGS_COMPILE_BEFORE` → `NIX_CFLAGS_COMPILE_BEFORE_<suffix>` mapping

The cc-wrapper's `add-flags.sh` calls `mangleVarList NIX_CFLAGS_COMPILE_BEFORE`
via `accumulateRoles`. `mangleVarListGeneric` maps each relative-platform var
(`NIX_CFLAGS_COMPILE_BEFORE`, `NIX_CFLAGS_COMPILE_BEFORE_FOR_BUILD`,
`NIX_CFLAGS_COMPILE_BEFORE_FOR_TARGET`) into the derivation-specific
`NIX_CFLAGS_COMPILE_BEFORE_x86_64_unknown_linux_gnu`. So setting
`env.NIX_CFLAGS_COMPILE_BEFORE` in a Nix derivation reaches the cross compiler's
`extraBefore`.

## Fix

```nix
env.NIX_CFLAGS_COMPILE_BEFORE =
  lib.optionalString (isCrossBuild || (stdenv.isPseudoCross or false))
    ("-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}"
    + " -isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}/${stdenv.hostPlatform.config}");
```

This puts two explicit `-isystem` entries into `extraBefore` — before cmake's
`-isystem glibc` in the final invocation. The resulting search order:

```
1. include/c++/15.2.0/            ← our -isystem BEFORE
2. include/c++/15.2.0/x86_64-unknown-linux-gnu/  ← our -isystem BEFORE
3. glibc-dev/include              ← cmake's -isystem
4. include/c++/15.2.0/backward/   ← built-in (deduplicated generic, but backward survives)
5. compiler headers...
```

- `cstdlib` found at 1. `#include_next <stdlib.h>` → glibc at 3. ✓
- `bits/c++config.h` from `version.h` (found at 1) → found at 2. ✓

## Iteration history and key learnings

| Commit | Condition | Flag | Result |
|--------|-----------|------|--------|
| `fbbf81253` | `isCrossBuild` | `-I` | `isCrossBuild = !canExecute = false` in pseudo-cross → no-op |
| `d0b8b6646` | `hostPlatform != buildPlatform` | `-I` | Nix attrset `!=` unreliable; same hash |
| `3faae5c20` | `isCrossBuild \|\| isPseudoCross` | `-I` in NIX_CFLAGS_COMPILE | `-I` silently deduplicated by GCC; `extraAfter` too late anyway |
| `ae4f068b7` | `isCrossBuild \|\| isPseudoCross` | `-isystem` in NIX_CFLAGS_COMPILE_BEFORE | Correct: both dirs, before cmake flags |

**Why `hostPlatform != buildPlatform` evaluates the same:** Nix attrset
comparison with `!=` is unreliable when platform sets contain thunks; the
expression may short-circuit or be memoized in a way that doesn't reflect the
actual structural difference. Always use explicit booleans (`isCrossBuild`,
`stdenv.isPseudoCross`) for cross-condition guards.

**Why `-I` is rejected for system dirs:** GCC issues a warning and keeps the
path at its built-in position, not the user-include position. Use `-isystem` to
establish ordering among system includes.

**Why `NIX_CFLAGS_COMPILE_BEFORE`:** The cc-wrapper places
`NIX_CFLAGS_COMPILE_BEFORE` in `extraBefore`, which is prepended to the entire
compiler invocation — before cmake's flags. `NIX_CFLAGS_COMPILE` goes in
`extraAfter`, after cmake's flags. To beat cmake's `-isystem`, you must be in
`extraBefore`.

## Affected scope

Any C++ package built in cross or pseudo-cross where cmake emits `-isystem
<glibc>/include` as a target include directory. This is common for packages
using `target_include_directories(... SYSTEM ...)` or `find_package` with
imported targets that propagate system includes.
