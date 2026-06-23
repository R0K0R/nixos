# 16 — dart: `close_range` conflicting C linkage, `-Werror`, GCC 15 + glibc 2.42

## Symptom

```
../../runtime/bin/process_linux.cc:286:16: error: conflicting C language linkage
declaration 'int dart::bin::close_range(unsigned int, unsigned int, int)' [-Werror]
  286 | extern "C" int close_range(unsigned int first, unsigned int last, int flags)
      |                ^~~~~~~~~~~
/nix/store/.../glibc-...-dev/include/unistd.h:1211:12: note: previous declaration
'int close_range(unsigned int, unsigned int, int)'
 1211 | extern int close_range (unsigned int __fd, unsigned int __max_fd,
      |            ^~~~~~~~~~~
../../runtime/bin/process_linux.cc:286:16: note: due to different exception specifications
cc1plus: all warnings being treated as errors
```

## Root cause

glibc 2.42 added `close_range()` to `unistd.h`. dart's `process_linux.cc`
declares its own `extern "C" int close_range(...)` — a conflicting declaration
with a different exception specification. GCC 15 treats this as an error; with
`-Werror` in dart's GN build config, the build fails.

This is an upstream dart bug: dart should either use the glibc declaration or
guard its own with `#ifndef __GLIBC__` / a version check.

Not pseudo-cross specific — would fail in any native build with GCC 15 + glibc 2.42.
The cross build triggers it because there is no binary cache hit for the
`x86_64-unknown-linux-gnu` (meteorlake) target.

## Package structure

dart has two nixpkgs derivations:

- `pkgs/development/compilers/dart/default.nix` — downloads a pre-built SDK
  binary from Google. Does not compile anything.
- `pkgs/development/compilers/dart/source/default.nix` — fetches dart source via
  `gclient`, builds with GN + ninja. This is what the cross build uses, because
  the pre-built binary's `selectSystem` map has no entry for
  `x86_64-unknown-linux-gnu`.

## Fix

In `source/default.nix`, the `postPatch` already patches
`build/config/compiler/BUILD.gn` to remove `-fsanitize=memory`:

```nix
sed --in-place 's/"-fsanitize=memory"//g' build/config/compiler/BUILD.gn
```

Add a second sed on the same file to remove `-Werror`:

```nix
sed --in-place 's/"-Werror"//g' build/config/compiler/BUILD.gn
```

## Where fixed

`/home/r0k0r/nixpkgs-contrib/pkgs/development/compilers/dart/source/default.nix`

## Cross-debug category

**Non-pattern: GCC 15 + glibc 2.42 upstream package bug.** Same class as
cross-debug/11 (ghostscript), cross-debug/23 (dart fpclassify). The `-Werror`
removal is the correct local fix; the proper upstream fix is for dart to not
redeclare `close_range` when glibc already provides it.
