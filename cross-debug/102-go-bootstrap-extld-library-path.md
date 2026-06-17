# cross-debug/102: Go — bootstrap `-extld` raw gcc missing LIBRARY_PATH for CRT objects

**Package:** `go` (1.25, 1.26)
**Files:** `pkgs/development/compilers/go/1.25.nix`, `pkgs/development/compilers/go/1.26.nix`

## Symptom

Building Go from source in pseudo-cross (`isCross && buildPlatform.config ==
targetPlatform.config`) fails during the `bootstrap` build phase with link errors:

```
/run/wrappers/bin/ld: cannot find Scrt1.o: No such file or directory
/run/wrappers/bin/ld: cannot find crti.o: No such file or directory
/nix/store/.../bin/x86_64-unknown-linux-gnu-gcc: error: linker command failed
  with exit code 1
```

or equivalently:
```
cannot find -lgcc_s
```

## Root Cause

Go's bootstrap procedure compiles a `cmd/go` tool using Go's own build system.
When linking Go programs that call into C (cgo) the Go linker invokes an
**external linker** (`-extld`) — by default the system `gcc` — to link the final
binary. In a pseudo-cross build that raw gcc binary is the prefixed cross wrapper
(`x86_64-unknown-linux-gnu-gcc`), NOT the nixpkgs cc-wrapper shell script.

The cc-wrapper shell script injects:
- `-B ${stdenv.cc.libc}/lib` — tells the linker where to find `Scrt1.o`, `crti.o`
- `-L ${stdenv.cc.libc}/lib` — tells the linker where to find `libgcc_s.so`

The raw gcc binary has no such injection. When it invokes `ld` it finds neither
the glibc startup objects nor `libgcc_s`, producing the "cannot find" errors.

This failure is pseudo-cross-specific because:
- In a native build `stdenv.cc` IS the cc-wrapper, which handles the `-B`/`-L`
  injection automatically at runtime.
- In a cross build where the tuples differ, Go typically doesn't reach this code
  path (external linking is handled differently).
- Only in pseudo-cross (same tuple, different `gcc.arch`) does Go activate external
  linking using the raw prefixed gcc without the cc-wrapper's path injection.

## Fix

Set `LIBRARY_PATH` before the Go bootstrap build so that gcc's built-in library
search can find the CRT objects and `libgcc_s`:

```nix
preBuild = ''
  ${lib.optionalString (isCross && stdenv.buildPlatform.config == stdenv.targetPlatform.config) ''
    # Pseudo-cross: buildPlatform and targetPlatform share the same config string but
    # differ in gcc.arch (e.g. meteorlake). Go's bootstrap linker calls raw gcc as
    # -extld, which lacks the cc-wrapper's -B/-L flags for glibc startup files.
    # Set LIBRARY_PATH so raw gcc can find Scrt1.o, crti.o, and libgcc_s.
    export LIBRARY_PATH="${stdenv.cc.libc.out}/lib:${lib.getLib stdenv.cc.cc}/lib''${LIBRARY_PATH:+:}''${LIBRARY_PATH:-}"
  ''}
  ...
'';
```

`stdenv.cc.libc.out` provides `Scrt1.o`/`crti.o`; `lib.getLib stdenv.cc.cc`
provides `libgcc_s.so`. Both are added to `LIBRARY_PATH` so gcc's linker can
find them without explicit `-B`/`-L` flags.

The `${LIBRARY_PATH:+:}${LIBRARY_PATH:-}` idiom appends any pre-existing
`LIBRARY_PATH` value to preserve pre-set paths while avoiding a trailing `:`.

## Why the guard matters

`isCross && buildPlatform.config == targetPlatform.config` targets pseudo-cross
specifically. Setting `LIBRARY_PATH` unconditionally would affect native Go builds
where the paths are already correct via the cc-wrapper, risking subtle library
shadowing if `LIBRARY_PATH` ever conflicts with the cc-wrapper's path injection.

## Pattern

Related to Pattern A: the raw prefixed gcc binary (not the cc-wrapper shell
script) is invoked directly by Go's build system. Unlike Pattern A1 (build system
can't find `gcc` by name), here the binary IS found and invoked — but it lacks
the cc-wrapper's runtime path injection. `LIBRARY_PATH` compensates by using
gcc's own library search fallback mechanism.
