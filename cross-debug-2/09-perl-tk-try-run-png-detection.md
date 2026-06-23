# 09 — perl-Tk: try_run failure for system libpng detection

## Symptom

```
No rule to make target 'png.h', needed by 'PNG/PNG.o'. Stop.
```

perl-Tk's `PNG/Makefile.PL` falls back to bundled libpng when it can't verify
system libpng works. The bundled copy doesn't have `png.h` in the expected location.

## Root cause

`PNG/Makefile.PL` uses a pattern like:
1. `pkg-config --cflags libpng` → finds system libpng header path
2. Compile-and-run a test binary to verify the found libpng actually works at runtime

Step 2 compiles a HOST binary and tries to run it. In cross builds (including
pseudo-cross where `CMAKE_CROSSCOMPILING` is true), this `try_run`-style check
fails because the build system assumes it can't execute HOST binaries. It falls
back to bundled libpng, which lacks `png.h`.

Note: the same package also had the `pkg-config libpng` subprocess visibility
issue (see fix #05). Both were needed.

## Fix

In nixpkgs-contrib, patched `perl-packages.nix` to bypass the try_run check
in cross builds — `pkg-config` already confirmed libpng is available, so the
runtime-execution verification is redundant:

```perl
# In cross builds, skip the try_run check — pkg-config already found
# system libpng and we trust it works (both BUILD and HOST are x86_64).
```

This is applied via a `postPatch` on the Tk package that patches the relevant
conditional in `PNG/Makefile.PL`.

The overlay fix (fix #05) then handles the `PKG_CONFIG_PATH` visibility.

## nixpkgs-contrib commit

`ca7b99a2a`

## Cross-debug category

**Pattern B / try_run (cross-debug/63 class):** cmake / custom Makefile.PL
try_run patterns fail in cross mode even when BUILD can execute HOST binaries.
The F14 mechanism handles cmake try_run via `CMAKE_PROJECT_INCLUDE` preload;
for Makefile.PL-level try_run the fix must be per-package.
