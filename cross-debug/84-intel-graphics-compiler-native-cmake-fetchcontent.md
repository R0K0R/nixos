# cross-debug/84: intel-graphics-compiler — NATIVE cmake sub-build fetches SPIRV-Headers at build time

## Problem

`intel-graphics-compiler-x86_64-unknown-linux-gnu-2.34.4` fails with:

```
fatal: unable to access 'https://github.com/KhronosGroup/SPIRV-Headers.git/':
  Could not resolve host: github.com
CMake Error at .../spirv-headers-populate-prefix/tmp/spirv-headers-populate-gitclone.cmake:50
```

The build path is inside `IGC/llvm-deps-16.0.6/build/src/NATIVE/`.

## Root cause

IGC's cmake build compiles some components twice: once for the HOST
(meteorlake, the final target) and once for NATIVE (the build machine, to run
code generators during the build).  The NATIVE build is a cmake sub-invocation
that configures independently from the top-level cmake.

The nixpkgs package correctly passes:
```
-DIGC_OPTION__USE_PREINSTALLED_SPIRV_HEADERS=ON
-DSPIRV-Headers_INCLUDE_DIR=${spirv-headers}/include
-DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR=${spirv-headers.src}
```

But these flags are top-level cmake flags.  The NATIVE sub-build calls cmake
fresh and does not inherit the parent cmake cache.  It falls back to cmake
`FetchContent` to download SPIRV-Headers at build time — which is blocked by
the Nix sandbox (no network).

This is a **cross-specific** bug: a non-cross build runs only one cmake
invocation (the NATIVE build IS the build), so the pre-fetched headers are
found.  The cross/pseudo-cross path adds the second NATIVE sub-invocation that
doesn't know about them.

## Fix

Dropped `intel-compute-runtime` (which depends on `intel-graphics-compiler`)
from `hardware.graphics.extraPackages`.  `intel-media-driver` (iHD) handles
VA-API hardware decode on Xe-LPG independently of IGC.

OpenCL/Level Zero compute support (needed for ML workloads, PyTorch XPU) is
deferred until either:
- Upstream nixpkgs fixes the NATIVE cmake FetchContent issue, or
- An overlay passes `-DIGNORE_FETCHCONTENT=ON` (or equivalent) into the NATIVE
  sub-build via a cmake preload file.

## Files

- `hosts/galaxybook4-pro360/hardware.nix` — `intel-compute-runtime` removed
  from `extraPackages`; `OCL_ICD_VENDORS` and `ZES_ENABLE_SYSMAN` env vars
  removed (no OpenCL runtime to configure)
