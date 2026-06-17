# cross-debug/85: hardware.graphics.enable32Bit — i686 builds fail in pseudo-cross

## Problem

`hardware.graphics.enable32Bit = true` causes `libgcrypt-i686-unknown-linux-gnu`
to fail during its test suite:

```
make[2]: *** [Makefile:1090: check-TESTS] Error 1
make[1]: *** [Makefile:1215: check-am] Error 2
```

This blocks `elfutils-i686` → `mesa-i686` → `graphics-drivers-32bit`.

## Root cause

`enable32Bit` adds the i686 variants of all `hardware.graphics.extraPackages`
to the system.  In a standard non-cross x86_64 NixOS build, i686 packages are
built via a straightforward cross (x86_64 build → i686 host).  In our
pseudo-cross setup, the i686 packages pass through an additional layer:

```
x86_64 (yulee, build)
  → x86_64+meteorlake (galaxybook4, host)
    → i686 (32-bit target)
```

The i686 libgcrypt test suite executes 32-bit binaries on yulee (znver5).
These fail either because the 32-bit test environment is incorrectly configured
in the double-cross setup, or because 32-bit library paths are wrong.

## Fix

Removed `enable32Bit = true` from `hardware.graphics`.  32-bit graphics
support (needed for Steam/Wine/Proton) is not required for the primary use
cases (VA-API hardware decode, niri compositor).

To add 32-bit gaming support in the future, the cleanest approach is:
- Test with a standard non-cross NixOS config first to confirm the i686
  builds themselves are correct
- Then investigate whether nixpkgs' cross-in-cross handling can be patched
  to skip tests for the innermost cross target (`doCheck = false` for i686
  packages in the meteorlake overlay)

## Files

- `hosts/galaxybook4-pro360/hardware.nix` — `enable32Bit` removed
