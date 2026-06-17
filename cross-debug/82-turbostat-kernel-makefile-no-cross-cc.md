# cross-debug/82: turbostat — kernel Makefile can't find compiler in cross sandbox

## Problem

`linuxPackages.turbostat-x86_64-unknown-linux-gnu-6.18.31` fails:

```
make: *** [Makefile:23: turbostat] Error 127
```

Exit 127 = command not found. The turbostat Makefile invokes a compiler by its
plain name (`cc` or `$(CC)` defaulting to `cc`) which is absent from the cross
sandbox PATH.

## Root cause

Same as cross-debug/80 (juceaide): the cross cc-wrapper only provides
triple-prefixed binaries (`x86_64-unknown-linux-gnu-gcc`), not plain `cc`/`gcc`.
The turbostat Makefile is a simple kernel tool Makefile that does not set `CC`
explicitly and relies on the default `cc` being present.

`linuxPackages` packages in a pseudo-cross setup are built for the HOST
(meteorlake). The cross cc-wrapper is in PATH but its plain-name symlinks are
absent, so any Makefile that calls bare `cc` gets "command not found."

See cross-debug/00 for the fundamental pattern.

## Fix

Dropped `linuxPackages.turbostat` from `modules/nixos/packages/hosts/galaxybook4-pro360.nix`.
It is a diagnostic-only tool. `intel_gpu_top` (from `intel-gpu-tools`), `s-tui`,
and `powertop` cover the same monitoring use cases.

An overlay fix is possible (add `pkgsBuildBuild.stdenv.cc` to nativeBuildInputs,
set `makeFlags = ["CC=…"]`) but not worth the maintenance cost for a CLI utility.

## Files

- `modules/nixos/packages/hosts/galaxybook4-pro360.nix` — turbostat removed
