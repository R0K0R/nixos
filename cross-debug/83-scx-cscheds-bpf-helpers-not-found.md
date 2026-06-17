# cross-debug/83: scx_cscheds — BPF C schedulers can't find bpf_helpers.h

## Problem

`scx_cscheds-x86_64-unknown-linux-gnu-0-unstable-2026-01-13` fails:

```
clang -g -O2 ... -target bpf ... -c scx_simple.bpf.c -o scx_simple.bpf.o
fatal error: 'bpf/bpf_helpers.h' file not found
   24 | #include <bpf/bpf_helpers.h>
make[2]: *** [...] Error 1
```

## Root cause

The C BPF schedulers (scx_cscheds) include `<bpf/bpf_helpers.h>` from libbpf.
In a pseudo-cross build, the include search path for BPF targets is not
correctly wired up — the cross include directories point to meteorlake-targeted
headers but the BPF `-target bpf` compilation searches a different set of
paths.

This is a cross include-path issue analogous to Pattern A (see cross-debug/00),
but for BPF target compilation rather than native compilation.

## Fix

Use `pkgs.scx.rustscheds` instead of the default `pkgs.scx.full`.  The
scheduler we want (`scx_bpfland`) is a **Rust** scheduler.  The Rust SCX
schedulers don't compile BPF programs directly from C — they embed pre-compiled
BPF skeletons — so `bpf_helpers.h` is never needed:

```nix
services.scx = {
  enable = true;
  package = pkgs.scx.rustscheds;
  scheduler = "scx_bpfland";
  extraArgs = [ "--power-mode" "powersave" ];
};
```

`scx.full` includes both `scx_rustscheds` and `scx_cscheds`.  `scx.rustscheds`
is the minimal subset that covers all Rust schedulers.

## Files

- `hosts/galaxybook4-pro360/power.nix` — `package = pkgs.scx.rustscheds`
