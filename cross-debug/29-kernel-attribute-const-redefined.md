# Linux kernel `objtool`: `__attribute_const__` redefined (GCC 15 + glibc 2.42)

**Package:** `linux-x86_64-unknown-linux-gnu-6.18.31`
**File:** `pkgs/os-specific/linux/kernel/build.nix`

## Symptom

```
/nix/store/.../glibc-x86_64-unknown-linux-gnu-2.42-dev/include/sys/cdefs.h:486:10:
  error: '__attribute_const__' redefined [-Werror]
/build/linux-6.18.31/tools/include/linux/compiler.h:122:10:
  note: this is the location of the previous definition
cc1: all warnings being treated as errors
make[6]: *** [...objtool/libsubcmd/exec-cmd.o] Error 1
```

## Root Cause

glibc 2.42's `sys/cdefs.h:486` and the kernel's `tools/include/linux/compiler.h:122`
both define `__attribute_const__` as `__attribute__((__const__))`. The definitions
are functionally identical but have minor whitespace differences in the token sequence;
GCC 15 warns on the redefinition.

The kernel builds host tools (objtool, etc.) with `-Werror`, promoting this unnamed
warning (`[-Werror]` without a specific `-W` category) to a hard error. Because the
warning has no named `-W` flag, it cannot be suppressed with `-Wno-specific-warning`
— only `-Wno-error` (strip the error promotion) or `-w` (suppress all warnings) work.

This is a companion to the `vsscanf` redundant-decls issue (doc 25) — both affect
host tool compilation under glibc 2.42 + GCC 15.

## Fix

Extend the existing `HOSTCFLAGS` make flag to also include `-Wno-error`:

```nix
"HOSTCFLAGS+=-Wno-redundant-decls -Wno-error"
```

`-Wno-error` prevents ALL host-tool warnings from becoming errors. This is safe for
our Nix cross build since the kernel target itself still compiles with full warnings;
only the host-side tools (objtool, etc.) are affected.

Applied in `pkgs/os-specific/linux/kernel/build.nix`.
