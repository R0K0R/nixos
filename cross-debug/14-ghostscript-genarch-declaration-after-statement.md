# Ghostscript: `genarch.c` Fails With `-Werror=declaration-after-statement` in Cross Build

**Package:** `ghostscript-x86_64-unknown-linux-gnu-10.06.0`
**File:** `pkgs/by-name/gh/ghostscript/package.nix`

## Symptom

```
/nix/store/.../glibc-x86_64-unknown-linux-gnu-2.42-61-dev/include/bits/stdint-uintn.h:24:1:
error: ISO C90 forbids mixed declarations and code [-Werror=declaration-after-statement]
   24 | typedef __uint8_t uint8_t;
cc1: some warnings being treated as errors
make[2]: *** [base/unix-aux.mak:68: soobj/aux/genarch] Error 1
```

## Root Cause

Ghostscript's build system sets `-Werror=declaration-after-statement` in CFLAGS via its
own Makefiles. These CFLAGS are applied to BUILD-platform auxiliary tools (`genarch`,
`echogs`) as well as the main HOST-platform build. In cross builds, these aux tools are
compiled with `$CC_FOR_BUILD` (correct) but still using the HOST platform's glibc headers
(via `-I/nix/store/...-glibc-x86_64-unknown-linux-gnu-...-dev/include`).

`genarch.c` includes `<stdint.h>` at line 206, inside `main()`. The HOST glibc 2.42's
`bits/stdint-uintn.h` has `typedef __uint8_t uint8_t` at file line 24, which lands
after executable code in `main()`, triggering the "declaration after statement" error.

## Why `CFLAGS=-std=gnu17` in `configureFlags` Didn't Work

`unix-gcc.mak` constructs:
```makefile
GCFLAGS= ... -Werror=declaration-after-statement ...  (line 369, hardcoded)
CFLAGS=$(CFLAGS_STANDARD) $(GCFLAGS) $(AC_CFLAGS) $(XCFLAGS)  (line 404)
CCAUX_=$(CCAUX) $(CFLAGS)  (line 611)
```

Ghostscript's make invocation passes `CFLAGS='...'` as a make variable on the command
line, overriding any environment `CFLAGS`. So `CFLAGS=-std=gnu17` from autoconf
configureFlags never reaches the actual compilation.

## Fix

`postPatch` to remove the flag directly from `base/unix-gcc.mak`:

```nix
postPatch = ''
  sed -i 's/-Werror=declaration-after-statement//g' base/unix-gcc.mak
'';
```
