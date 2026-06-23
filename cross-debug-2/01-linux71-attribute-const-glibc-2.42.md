# 01 — Linux 7.1 kernel: `__attribute_const__` redefinition with glibc 2.42

## Symptom

`resolve_btfids` (and `objtool`) fail to compile during the Linux 7.1 kernel build:

```
tools/include/linux/compiler.h:122:0: error: "__attribute_const__" redefined [-Werror=builtin-macro-redefined]
  # define __attribute_const__
```

`resolve_btfids/Makefile` hardcodes `HOSTCFLAGS_resolve_btfids += -Wall -Werror`, making
this warning fatal.

## Root cause

glibc 2.42 added a definition of `__attribute_const__` in `sys/cdefs.h`:

```c
# define __attribute_const__ __attribute__ ((__const__))
```

The kernel `tools/include/linux/compiler.h` (used by host build tools like
`resolve_btfids`, `objtool`, `genksyms`) previously defined it as empty:

```c
# define __attribute_const__
```

GCC 15 warns when a macro is redefined to a **different** replacement list. Empty and
`__attribute__ ((__const__))` are different, so the warning fires. With `-Werror` in
the host tools Makefile this is fatal.

**Note:** The file to patch is `tools/include/linux/compiler.h`, NOT the runtime
kernel header `include/linux/compiler_attributes.h`. Host build tools use their own
copy under `tools/`.

## C standard basis

C11 §6.10.3: identical replacement lists in macro redefinition are accepted silently.
The fix makes the kernel definition token-for-token identical to glibc's, including
the space before `((`

## Fix (4 iterations)

### Iteration 1 — WRONG file
Patched `include/linux/compiler_attributes.h`. Host tools use `tools/include/linux/compiler.h`.
Build still failed.

### Iteration 2 — Wrong approach: `#undef` before include
Added `#undef __attribute_const__` before `#include <sys/types.h>`. Broke objtool:
`errno.h:37` uses `__attribute_const__` before `sys/cdefs.h` redefines it, so the
undef left it undefined when needed.

### Iteration 3 — Wrong spacing
Changed definition to `__attribute__((__const__))` (no space before `(`). glibc has
`__attribute__ ((__const__))` (with space). GCC 15 still warned — replacement lists
must match **token-for-token** including whitespace.

### Iteration 4 — CORRECT
Changed to `__attribute__ ((__const__))` with the space. GCC accepts identical
replacement lists silently. Kernel built successfully.

## Final patch

`pkgs/os-specific/linux/kernel/attribute-const-glibc-2.42-compat.patch`:

```diff
--- a/tools/include/linux/compiler.h
+++ b/tools/include/linux/compiler.h
@@ -119,7 +119,7 @@
 
 #ifndef __attribute_const__
-# define __attribute_const__
+# define __attribute_const__ __attribute__ ((__const__))
 #endif
```

Applied in `build.nix` (kernel build infrastructure) for kernel versions ≥ 5.0.

## HOSTCFLAGS cleanup

Also removed `-Wno-macro-redefined` from `common-flags.nix` (see fix #02): GCC has
no such named flag. Kept `-Wno-error` (for objtool) and `EXTRA_WARNINGS=` (for libbpf
which adds `-Wredundant-decls` via `EXTRA_WARNINGS` after `HOSTCFLAGS`).

## Upstream status

This patch does not exist in upstream nixpkgs as of 2026-06-22. Valid upstream
contribution candidate — submit to Arnaldo Carvalho de Melo / linux-kernel or
nixpkgs.

## Cross-debug category

Non-pattern: this is a GCC 15 + glibc 2.42 compiler/library version bump issue,
not a pseudo-cross-specific problem. Would affect any nixpkgs build using kernel
7.1 host tools with glibc 2.42 + GCC 15.
