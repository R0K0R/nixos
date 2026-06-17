# `network` Haskell: `collect2: cannot find 'ld'` in Pseudo-Cross Build

**Package:** `network-x86_64-unknown-linux-gnu-3.2.8.0`
**File:** `pkgs/development/haskell-modules/configuration-nix.nix`

## Symptom

```
configure:3249: /nix/store/.../x86_64-unknown-linux-gnu-gcc-wrapper-15.2.0/bin/x86_64-unknown-linux-gnu-gcc -fuse-ld=gold -Wl,--no-as-needed   conftest.c  >&5
collect2: fatal error: cannot find 'ld'
compilation terminated.
configure: error: C compiler cannot create executables
```

The error appears during `buildPhase`, not `configurePhase`, because `network` uses
`build-type: Configure` in its Cabal file — the autoconf `./configure` runs inside
`./Setup build`, not during `./Setup configure`.

## Root Cause

Three interacting factors:

1. **`-fuse-ld=gold` is in `CFLAGS`** (via the cross-gcc-wrapper's NIX_CFLAGS mechanism)
   because the cross toolchain for the pseudo-cross meteorlake target uses gold.

2. **The cross-gcc was built with `--build=--host=--target=x86_64-unknown-linux-gnu`**
   (all three tuples are identical). GCC therefore treats itself as a "native" compiler.
   When `collect2` resolves `-fuse-ld=gold`, it looks for the **unprefixed** `ld.gold`
   on PATH — not `x86_64-unknown-linux-gnu-ld.gold`.

3. **Only `x86_64-unknown-linux-gnu-ld.gold` exists** in the cross-binutils-wrapper's
   bin directory; there is no unprefixed `ld.gold` shim.

## Why the Previous `iserv-proxy`/`network` Override Didn't Help

The previous override used `lib.mapAttrs` to apply only `enableExternalInterpreter = false`
to both packages. No `preBuild` was added for `network`.

## Why the PATH Symlink Approach Fails

The first attempted fix created a `$TMPDIR/nix-ld-shims/ld.gold` symlink and prepended
the directory to PATH. This doesn't work because `collect2` does NOT search PATH for the
linker. Instead, it searches the **same directory as the base `ld`** (i.e., the bintools-
wrapper bin dir). Only `x86_64-unknown-linux-gnu-ld.gold` exists there; no `ld.gold`.

## Root of the CFLAGS Injection

The `-fuse-ld=gold -Wl,--no-as-needed` in CFLAGS comes from GHC's settings file:
```
("C compiler link flags","-fuse-ld=gold  -Wl,--no-as-needed")
```
Cabal reads these settings and passes them as `CFLAGS` when it invokes `./configure`
inside `./Setup build`. The configure script then uses them when testing the C compiler.

## Why CFLAGS Strip in preBuild Fails

Cabal **sets CFLAGS explicitly in the subprocess environment** when it invokes `./configure`,
overriding any modification made to the outer shell's CFLAGS variable. Setting
`export CFLAGS="${CFLAGS//-fuse-ld=gold/}"` in `preBuild` has no effect.

Also: for `build-type: Configure` packages, Cabal calls `./configure` during `configurePhase`
(inside `./Setup configure`), NOT during `buildPhase`. So `preBuild` runs too late anyway.

## Why Wrapping CC with PATH Symlink Fails

`collect2` does not search PATH for the linker. When `-fuse-ld=gold` is passed, it looks
for `ld.gold` in the **same directory as the base `ld`** (the bintools-wrapper bin/).
Only `x86_64-unknown-linux-gnu-ld.gold` exists there; no unprefixed `ld.gold`.

## Fix (Working)

In `configuration-nix.nix`, use `preConfigure` (which runs before `configurePhase`) to
wrap the network package's `configure` script with one that strips `-fuse-ld=gold` from
the CFLAGS it receives in its subprocess environment:

```nix
network = lib.pipe super.network [
  (overrideCabal { enableExternalInterpreter = false; })
  (overrideCabal (drv: lib.optionalAttrs (!canExecute) {
    preConfigure =
      (drv.preConfigure or "")
      + ''
        if [[ -f configure ]]; then
          mv configure configure.real
          chmod +x configure.real  # mv preserves perms but Nix sandbox strips x bit
          printf '#!/bin/bash\nexport CFLAGS="''${CFLAGS//-fuse-ld=gold/}"\nexec "$(dirname "$0")/configure.real" "$@"\n' \
            > configure
          chmod +x configure
        fi
      '';
  }))
];
```

Key points:
- `preConfigure` runs before `configurePhase`, which is when `./Setup configure` calls `./configure`
- The wrapper strips `-fuse-ld=gold` from the CFLAGS env var for the configure subprocess
- `chmod +x configure.real` is required: the Nix sandbox strips the execute bit during `mv`
- `canExecute = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;` (top-level let in the file)
