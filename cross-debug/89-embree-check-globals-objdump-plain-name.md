# cross-debug/89: embree check_globals.cmake — objdump plain name absent in pseudo-cross

**Package:** `embree-4.4.0.drv` (host=meteorlake, nativeBuildInput of openimagedenoise)
**File:** `common/cmake/check_globals.cmake`

## Symptom

```
CMake Error at /build/source/common/cmake/check_globals.cmake:9 (string):
  string sub-command REPLACE requires at least four arguments.

make[2]: *** [kernels/CMakeFiles/embree_sse42_check_globals.dir/build.make:70: kernels/CMakeFiles/embree_sse42_check_globals] Error 1
```

Build reaches ~58%, then fails on the `embree_sse42_check_globals` custom target.

## Root Cause

**Pattern A** — same as ispc/clang++ and OSL LLVM_BC_GENERATOR, but for `objdump`.

`check_globals.cmake` is invoked as a cmake `-P` script custom target:
```cmake
execute_process(COMMAND objdump -C -t ${file} OUTPUT_VARIABLE output)
string(REPLACE "\n" ";" output ${output})   # line 9 — fails if output is empty
```

In pseudo-cross builds the bintools-wrapper provides only prefixed names
(`x86_64-unknown-linux-gnu-objdump`); plain `objdump` is absent from PATH.
`execute_process` silently returns empty output when the command is not found.
Empty `${output}` makes cmake see `string(REPLACE "\n" ";" output)` — only
3 arguments — causing the arity error.

## Fix

Patch `check_globals.cmake` in `postPatch` to guard against empty output.
The check is advisory (detects accidental global variables in SSE-specific
kernels); skipping it when `objdump` is absent is safe.

```nix
sed -i '/^string(REPLACE/i if(NOT output)\n  return()\nendif()' \
  common/cmake/check_globals.cmake
```

Applied in `pkgs/by-name/em/embree/package.nix` postPatch.
