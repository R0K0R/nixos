# `asymptote-3.09`: `rpc/types.h` not found — libtirpc cross pkg-config not queried

**Package:** `asymptote-x86_64-unknown-linux-gnu-3.09` (via `texlive-combined`)
**File:** `pkgs/by-name/as/asymptote/package.nix`

## Symptom

```
configure: *** Broken rpc headers; XDR/V3D support disabled ***
make: *** No rule to make target 'rpc/types.h', needed by 'xstream.o'.  Stop.
```

## Root Cause

Asymptote's `configure.ac` uses a custom `PKG_CONFIG` m4 macro that calls
`pkg-config` directly (not via `$PKG_CONFIG`):

```m4
AC_DEFUN([PKG_CONFIG],[
ifdef(
   [PKG_CHECK_MODULES],
   $1="$2 "$(pkg-config --silence-errors $3 $4 || echo),
   $1="$2 "
)
```

In a nixpkgs cross build, unqualified `pkg-config` in PATH is the **native**
(build machine) pkg-config. The HOST libtirpc's `.pc` file is only visible to
the **cross** pkg-config wrapper (e.g., `x86_64-unknown-linux-gnu-pkg-config`),
which is exposed via `$PKG_CONFIG` but not as bare `pkg-config`.

Result: `pkg-config --cflags libtirpc` returns nothing, `-I…/tirpc` is never
added to `CPPFLAGS`, the `AC_COMPILE_IFELSE` test for `xstream.h` fails, and
configure disables XDR. The Makefile still lists `rpc/types.h` as a dependency
for `xstream.o`, so `make` fails.

## Fix

Add `-I${libtirpc.dev}/include/tirpc` to `NIX_CFLAGS_COMPILE`. The nixpkgs
cc-wrapper always passes `NIX_CFLAGS_COMPILE` to every compiler invocation,
including configure's `AC_COMPILE_IFELSE` tests. With this flag the test finds
`rpc/types.h` and enables XDR support.

```nix
env.NIX_CFLAGS_COMPILE = "-I${boehmgc.dev}/include/gc"
  + lib.optionalString stdenv.hostPlatform.isLinux " -I${libtirpc.dev}/include/tirpc";
```

The `libtirpc` reference is safe because it is only evaluated when
`stdenv.hostPlatform.isLinux` is true, and `libtirpc` is already in
`buildInputs` under the same condition.

## Note

`libtirpc` puts its headers under `include/tirpc/rpc/`, not `include/rpc/`.
The `-I…/include/tirpc` flag is what makes `#include <rpc/types.h>` resolve to
`include/tirpc/rpc/types.h`. Without this flag the native include path has no
`rpc/types.h` in the Nix sandbox.
