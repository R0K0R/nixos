# cross-debug/70: gtk3-immodule.cache fails in cross builds (exec stack / dlopen)

## Problem

`gtk3-immodule.cache` derivation fails on yulee (BUILD machine):

```
Cannot load module .../fcitx5-with-addons-5.1.19/lib/gtk-3.0/3.0.0/immodules/im-fcitx5.so:
  libgcc_s.so.1: cannot enable executable stack as shared object requires: Invalid argument
.../im-fcitx5.so does not export GTK+ IM module API:
  libgcc_s.so.1: cannot enable executable stack as shared object requires: Invalid argument
```

## Root cause

`nixos/modules/i18n/input-method/default.nix` generates the GTK3 immodule cache
by running `gtk-query-immodules-3.0` (HOST binary) which dlopen's HOST IM modules.

In cross builds, HOST `im-fcitx5.so`'s dependency chain (HOST libstdc++.so.6 →
libgcc_s.so.1) triggers an exec stack check that fails in the nix build sandbox.
Investigation:

- `im-fcitx5.so` GNU_STACK: `RW` (not executable) — OK
- `x86_64-unknown-linux-gnu-gcc-15.2.0-lib/libgcc_s.so.1` GNU_STACK: `RW` — OK
- `x86_64-unknown-linux-gnu-nolibc-gcc-15.2.0-lib/libgcc_s.so.1` GNU_STACK: `RWE` — BAD
- `libstdc++.so.6` RUNPATH only includes glibc path (no gcc-lib), so `libgcc_s.so.1`
  resolution falls through to the nolibc bootstrap variant which has `RWE`.

The nix build sandbox blocks `mprotect(PROT_EXEC)` → EINVAL → dlopen failure.

The `emulatorAvailable` guard in the NixOS module returns `true` for pseudo-cross
(same ISA, no emulator needed) even though HOST library loading fails.

## Fix

Added `enableGtk3 = false` to `modules/nixos/i18n/fcitx5.nix`.

**This is correct regardless of cross compilation**: the GTK3 immodule cache is
only needed for X11/GTK3 apps that use the GTK IM module for input. On Wayland
(niri), fcitx5 communicates via the Wayland text-input-v3 protocol and D-Bus —
the GTK3 immodule cache is not used by any Wayland-native application.

## Files

- `modules/nixos/i18n/fcitx5.nix`
