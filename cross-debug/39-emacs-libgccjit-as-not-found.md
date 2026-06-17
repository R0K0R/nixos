# emacs: libgccjit configure test fails — plain `as` missing from sandbox PATH

**Package:** `emacs-pgtk-x86_64-unknown-linux-gnu-30.2`
**File:** `pkgs/applications/editors/emacs/make-emacs.nix`

## Symptom

```
checking for gcc_jit_context_acquire in -lgccjit... yes
checking for libgccjit.h... yes
configure: error: The installed libgccjit failed to compile and run a test program
```

## Root Cause (full analysis)

In a pseudo-cross build (build=x86_64-linux, host=x86_64-unknown-linux-gnu, same
ISA), the emacs configure test for libgccjit:

1. Compiles a test binary (using the cross GCC wrapper)
2. Runs it: the binary calls `gcc_jit_context_compile()`
3. libgccjit internally invokes its own GCC driver (from `libgccjit.so`'s store
   path) to compile a small C function to a .so
4. That GCC driver calls the plain `as` assembler to assemble the .s file

**The issue**: in the Nix build sandbox, plain `as` is not in PATH.

The cross binutils-wrapper setup hook adds:
```
/nix/store/<hash>-x86_64-unknown-linux-gnu-binutils-2.46/bin
```
to PATH. That `bin/` directory only contains **prefixed** tools:
`x86_64-unknown-linux-gnu-as`, `x86_64-unknown-linux-gnu-ld`, etc.

Plain `as` lives in `<hash>/x86_64-unknown-linux-gnu/bin/as` (the
target-native bin subdir), which is NOT added to PATH.

libgccjit's GCC driver invokes `as` (no prefix), which it finds via PATH.
Without plain `as`, `gcc_jit_context_compile()` returns NULL → test fails.

**Confirmed outside sandbox**: on yulee (the build machine), running jittest
with the system `/usr/bin/as` (Ubuntu binutils 2.42) causes a SIGSEGV in `as`,
giving the misleading "Segmentation fault signal terminated program as" error.
The Ubuntu `as` crashes on GCC 15 assembly output (version mismatch or
AVX/architecture opcode issue). With the cross binutils' `as` in PATH first,
the test returns `val=42, exit=0`.

**In the sandbox**: no `/usr/bin/as` is available (not in sandbox paths). The
only `as` candidates are the cross binutils prefixed tools — none are plain
`as`. `gcc_jit_context_compile()` returns NULL silently.

## Fix

Add `${stdenv.cc.bintools.bintools}/${stdenv.hostPlatform.config}/bin` to PATH
in `preConfigure`. This injects the target-native bin directory of the raw
cross binutils, which contains plain `as`.

```nix
export PATH="${stdenv.cc.bintools.bintools}/${stdenv.hostPlatform.config}/bin:$PATH"
```

Applied in the preConfigure block that's already conditioned on the pseudo-cross
case (`buildPlatform != hostPlatform && same ISA`).

## Notes

- The previous `LD_LIBRARY_PATH` / `LIBRARY_PATH` and configure sed patch are
  still needed alongside this fix.
- `libGccJitLibraryPaths[0]` (`libgccjit/lib/gcc`) is an empty dir; the actual
  CRT files are at `lib/gcc/x86_64-unknown-linux-gnu/15.2.0/` which GCC finds
  via its built-in exec_prefix spec, not LIBRARY_PATH.
- The failing `which as` on yulee (outside sandbox) is a separate Ubuntu `which`
  bug; the `as` binary itself works.
