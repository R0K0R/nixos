# max98390-hda / ipu-bridge-fix: `gcc: command not found` in cross module builds

**Packages:**
- `max98390-hda-1.0-6.18.31.drv` (from `${samsung-galaxy-book-linux-fixes}/nixos/max98390-hda-module.nix`)
- `ipu-bridge-fix-1.4-6.18.31.drv` (from `hosts/galaxybook4-pro360/webcam.nix`)

## Symptom

```
warning: the compiler differs from the one used to build the kernel
  The kernel was built by: x86_64-unknown-linux-gnu-gcc (GCC) 15.2.0
  You are using:           
  CC [M]  max98390_hda.o
bash: line 1: gcc: command not found
make[4]: *** [.../Makefile.build:287: max98390_hda.o] Error 127
```

## Root Cause

The kernel's top-level `Makefile` sets:
```makefile
CC = $(CROSS_COMPILE)gcc
```

When out-of-tree modules are built via `make -C ${kernel.dev}/lib/modules/.../build M=...`,
the generated `build/Makefile` does not embed `CROSS_COMPILE` — it just re-includes the
kernel's source `Makefile`. With `CROSS_COMPILE` unset, `CC = gcc`.

In the cross sandbox, `nativeBuildInputs` includes the cross GCC wrapper
(`x86_64-unknown-linux-gnu-gcc-wrapper`) which adds `x86_64-unknown-linux-gnu-gcc` to
PATH — but NOT plain `gcc`. So `CC = gcc` fails with "command not found".

The Clang case is handled correctly: `max98390-hda-module.nix` passes `CC=clang` for LLVM
kernels. The GCC case was never fixed.

## Fix

### `ipu-bridge-fix` (`hosts/galaxybook4-pro360/webcam.nix`)

Add `gccMakeFlags` for cross builds:

```nix
isCross = !pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
gccMakeFlags =
  lib.optionalString (!kernelUsesClang && isCross) "CC=${cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc";
...
buildPhase = ''
  make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
    M=$PWD modules ${clangMakeFlags} ${gccMakeFlags}
'';
```

### `max98390-hda` (`hosts/galaxybook4-pro360/samsung-fixes.nix`)

The upstream `samsung-speaker-fix.nix` module builds `max98390-hda` internally, so we
can't override its `makeFlags` without replacing the import. Changed `samsung-fixes.nix`
to NOT import `samsung-speaker-fix.nix` and instead:

1. Call `kernelPackages.callPackage "${fixes}/nixos/max98390-hda-module.nix" {...}` directly
2. Apply `.overrideAttrs` to add `CC=` for the cross GCC case
3. Inline the `i2cSetupScript` bash script and systemd service that the upstream module provided

```nix
max98390-hda = (kernelPackages.callPackage "${fixes}/nixos/max98390-hda-module.nix" {
  sourceType = "local";
  localSrc = "${fixes}/speaker-fix/src";
}).overrideAttrs (old: lib.optionalAttrs (!kernelUsesClang && isCross) {
  makeFlags = (old.makeFlags or []) ++ [
    "CC=${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}gcc"
  ];
});
```

## Notes

- `pkgs.stdenv.cc.targetPrefix` is `x86_64-unknown-linux-gnu-` in the pseudo-cross build.
- `pkgs.stdenv.cc.targetPrefix` is `""` in native builds, so the fix is no-op there.
- The clang case already passed `CC=` explicitly — this brings GCC to parity.
- Both modules use `stdenvNoCC.mkDerivation`, so the stdenv setup hooks don't set `CC`.
