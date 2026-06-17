# Linux kernel resolve_btfids/libbpf: `-Wpacked` error (GCC 15)

**Package:** `linux-x86_64-unknown-linux-gnu-6.18.31`
**File:** `pkgs/os-specific/linux/kernel/build.nix`

## Symptom

```
/include/linux/if_ether.h:177:1: error: packed attribute is unnecessary for 'ethhdr' [-Werror=packed]
  177 | } __attribute__((packed));
      | ^
cc1: all warnings being treated as errors
make[6]: *** [...resolve_btfids/libbpf/staticobjs/netlink.o] Error 1
```

## Root Cause

GCC 15 added `-Wpacked` to `-Wall`. The libbpf Makefile does:
```makefile
override CFLAGS += -Werror -Wall
```

This adds `-Werror -Wall` AFTER any HOSTCFLAGS/EXTRA_CFLAGS from the kernel build
system. Even with `-Wno-packed` in HOSTCFLAGS, `-Wall` re-enables it.

`linux/if_ether.h:177` uses `__attribute__((packed))` on an already-naturally-
aligned struct; GCC 15 now warns about this as redundant.

## Fix

Extended the existing `postPatch` sed in `build.nix` to also append `-Wno-packed -Wno-error` after `-Wall` in the libbpf Makefile:

```bash
sed -i 's/override CFLAGS += -Werror -Wall/& -Wno-redundant-decls -Wno-packed -Wno-error/' tools/lib/bpf/Makefile
```

The `-Wno-error` catchall prevents any additional new GCC 15 warnings in
glibc/kernel headers from being promoted to errors by libbpf's own `-Werror`.

**Status: FIXED** (part of combined sed with `-Wno-redundant-decls` fix from doc 25)
