# qtbase: `stdlib.h: No such file or directory` (cmake -isystem deduplication)

**Package:** `qtbase-x86_64-unknown-linux-gnu-6.11.0`
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

## Symptom

```
In file included from .../cstdlib:83:
fatal error: stdlib.h: No such file or directory
  #include_next <stdlib.h>
```

## Root Cause (full analysis)

cmake interrogates the cross-compiler's implicit include dirs (via `g++ -E -v`) and
re-emits them as explicit `-isystem` flags in every compile command. For the cross GCC
configured with `--with-native-system-header-dir=glibc/include`, cmake emits:

```
-isystem glibc-dev/include
```

GCC's built-in include search order for C++ is:
1. c++/15.2.0 (from --with-gxx-include-dir, GCC built-in)
2. glibc/include (from --with-native-system-header-dir, GCC built-in)

But when cmake adds `-isystem glibc/include` explicitly and GCC deduplicates same-dir
entries, the explicit `-isystem` position wins over the built-in position. Effective order:

1. `-isystem glibc/include` (cmake explicit, now FIRST)
2. c++/15.2.0 (GCC built-in)
3. c++/15.2.0/arch, c++/15.2.0/backward, etc.

`#include <cstdlib>` finds `cstdlib` at position 2.
`#include_next <stdlib.h>` searches from position 3 onwards — glibc was at position 1,
already skipped — so `stdlib.h` is not found.

**Why `-I c++/15.2.0` in extraBefore doesn't work:** GCC deduplicates `-I /path` with
a matching built-in system dir, keeping the dir at its built-in position (AFTER the
explicit `-isystem glibc`). So the effective order is still glibc before c++/15.2.0.

## Fix

Use `-isystem c++/15.2.0` (not `-I`) in `NIX_CFLAGS_COMPILE_BEFORE` (→ extraBefore).
An explicit `-isystem` entry placed BEFORE cmake's flags lands in GCC's system include
list BEFORE cmake's `-isystem glibc`, giving the correct order:

1. `-isystem c++/15.2.0` (our extraBefore, now FIRST)
2. `-isystem glibc/include` (cmake)
3. c++/15.2.0/arch (GCC built-in, c++/15.2.0 deduplicated to position 1)
4. ...

`#include <cstdlib>` → found at position 1 ✓
`#include_next <stdlib.h>` → searches from position 2 → glibc ✓

```nix
env = {
  NIX_CFLAGS_COMPILE = "-DNIXPKGS_QT_PLUGIN_PREFIX=\"${qtPluginPrefix}\"";
} // lib.optionalAttrs isCrossBuild {
  NIX_CFLAGS_COMPILE_BEFORE = "-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}";
};
```

**Status: FIXED** (changed from `-I` to `-isystem` in NIX_CFLAGS_COMPILE_BEFORE)
