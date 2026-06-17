# Emacs libgccjit configure test: JIT linker can't find crti.o / libgcc

**Package:** `emacs-pgtk-x86_64-unknown-linux-gnu-30.2`
**File:** `pkgs/applications/editors/emacs/make-emacs.nix`

## Symptom

```
configure: error: The installed libgccjit failed to compile and run a test program
```

The test binary compiles and links against `-lgccjit` successfully. At runtime,
`gcc_jit_context_compile()` fails with:

```
/nix/store/.../binutils-2.46/bin/ld.bfd: cannot find crti.o: No such file or directory
/nix/store/.../binutils-2.46/bin/ld.bfd: cannot find crtbeginS.o: No such file or directory
/nix/store/.../binutils-2.46/bin/ld.bfd: cannot find -lgcc: No such file or directory
libgccjit.so: error: error invoking gcc driver
```

## Root Cause

When `gcc_jit_context_compile()` runs, libgccjit internally invokes the GCC
driver to link the JIT output into a shared library. This internal driver call
needs:
- `crti.o` → in glibc's lib dir (`glibc-x86_64-unknown-linux-gnu/lib/`)
- `crtbeginS.o`, `libgcc.a` → in the cross libgcc dir
  (`libgcc-x86_64-unknown-linux-gnu/lib/gcc/x86_64-unknown-linux-gnu/15.2.0/`)

`LIBRARY_PATH` is already set as a derivation `env` attribute (pointing to all
the right cross-toolchain paths) by the existing `libGccJitLibraryPaths` logic.
However, Nix **setup hooks** run during the build phase and prepend additional
paths to `LIBRARY_PATH` for each dependency — potentially shadowing or
reordering the cross paths. The `LIBRARY_PATH` env attr is set early but by
configure time it may differ.

## Fix

Re-export `LIBRARY_PATH` explicitly in `preConfigure` (after setup hooks have
run) to ensure the cross CRT paths are definitely present:

```nix
preConfigure = lib.optionalString (...) ''
  export LD_LIBRARY_PATH="..."   # (existing: for test binary dynamic linking)
  export LIBRARY_PATH="${lib.concatStringsSep ":" libGccJitLibraryPaths}''${LIBRARY_PATH:+:$LIBRARY_PATH}"
  sed -i '/# Check if libgccjit really works\./{...}' configure
'';
```

`libGccJitLibraryPaths` already includes:
- `libgccjit/lib/gcc` 
- `stdenv.cc.libc/lib` (glibc → crti.o)
- `stdenv.cc.cc.lib.libgcc/lib` (crtbeginS.o, libgcc.a)

## Verification

Manual test confirmed: the libgccjit test binary succeeds when both
`LIBRARY_PATH` and `LD_LIBRARY_PATH` are set to the cross CRT paths.

**Status: FIXED**
