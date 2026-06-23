# 15 — libcanberra: libtool parallel install race condition

## Symptom

```
x86_64-unknown-linux-gnu-ld.bfd: cannot find -lcanberra-gtk3: No such file or directory
collect2: error: ld returned 1 exit status
libtool: install: error: relink `libcanberra-gtk3-module.la' with the above command before installing it
make[2]: *** [Makefile:978: install-gtk3moduleLTLIBRARIES] Error 1
```

## Root cause

libcanberra has `enableParallelBuilding = true`. When `make install` runs in
parallel, libtool attempts to relink `libcanberra-gtk3-module.la` using
`-lcanberra-gtk3` before `libcanberra-gtk3.so` has been installed to `$out/lib`.

How libtool relink works: during `make install`, libtool detects cross-compilation
mode and relinks each shared library to use the final install paths instead of
the build-tree paths. The relink command for `libcanberra-gtk3-module.la`
includes `-lcanberra-gtk3`, expecting the library to be findable via `-L` flags.
In parallel install, the library may not yet be in `$out/lib` when the module's
relink command fires.

This is not cross-specific in principle — the race can occur in native builds too
— but cross builds trigger libtool's relink path more aggressively because libtool
always relinks in cross mode.

## Fix

Add `enableParallelInstalling = false` to `pkgs/by-name/li/libcanberra/package.nix`
in nixpkgs-contrib. This keeps parallel compilation but serialises the install
phase, ensuring `libcanberra-gtk3.so` is installed before
`libcanberra-gtk3-module.la` is relinked.

```nix
enableParallelBuilding = true;
enableParallelInstalling = false;
```

## Where fixed

`/home/r0k0r/nixpkgs-contrib/pkgs/by-name/li/libcanberra/package.nix`

## Cross-debug category

**libtool cross-relink ordering.** In cross mode, libtool always relinks during
install (to fix up library paths). Parallel install creates a race between peer
libraries being installed in the same `make install` run. Fix: serialise the
install step with `enableParallelInstalling = false`.
