# Linux kernel host tools: `-Wredundant-decls` errors (GCC 15 + glibc 2.42)

**Package:** `linux-x86_64-unknown-linux-gnu-6.18.31`
**File:** `pkgs/os-specific/linux/kernel/build.nix`

## Symptoms

### Symptom 1 — objtool/exec-cmd.o (vsscanf)
```
error: redundant redeclaration of 'vsscanf' [-Werror=redundant-decls]
```

### Symptom 2 — resolve_btfids/libbpf (wcstoumax)
```
/include/inttypes.h:394:34: error: redundant redeclaration of 'wcstoumax' [-Werror=redundant-decls]
cc1: all warnings being treated as errors
make[6]: *** [...resolve_btfids/libbpf/staticobjs/libbpf.o] Error 1
```

## Root Cause

glibc 2.42 declares `vsscanf`/`wcstoumax`/`wcstoimax` twice in stdio.h/inttypes.h
as part of C23 redirects. GCC 15 treats `-Wredundant-decls` as an error because
the kernel builds host tools with `-Werror`.

**Two separate code paths affected:**

1. **objtool** — uses `HOSTCFLAGS` directly. `HOSTCFLAGS+=-Wno-redundant-decls`
   in `makeFlags` suppresses the warning.

2. **resolve_btfids/libbpf** — `tools/lib/bpf/Makefile` does:
   ```makefile
   CFLAGS := $(EXTRA_CFLAGS)          # ← HOSTCFLAGS passed via HOST_OVERRIDES
   override CFLAGS += -Werror -Wall   # ← GCC 15: -Wall now includes -Wredundant-decls!
   ```
   GCC 15 includes `-Wredundant-decls` in `-Wall`. Since `-Wall` is appended AFTER
   EXTRA_CFLAGS, it re-enables the warning even if `-Wno-redundant-decls` was in
   EXTRA_CFLAGS/HOSTCFLAGS.

   Additionally, GCC 15 includes `-Wpacked` in `-Wall`, which warns about
   `__attribute__((packed))` on already-aligned structs in `linux/if_ether.h`.
   (See doc 31.)

## Fix

Two-part fix in `pkgs/os-specific/linux/kernel/build.nix`:

**`makeFlags`** — suppress via HOSTCFLAGS (covers objtool):
```nix
"HOSTCFLAGS+=-Wno-redundant-decls -Wno-error"
```

**`postPatch`** — append suppressions AFTER `-Wall` in the libbpf Makefile,
plus `-Wno-error` as a catchall for any other new GCC 15 warnings:
```bash
sed -i 's/override CFLAGS += -Werror -Wall/& -Wno-redundant-decls -Wno-packed -Wno-error/' tools/lib/bpf/Makefile
```

**Status: FIXED**
