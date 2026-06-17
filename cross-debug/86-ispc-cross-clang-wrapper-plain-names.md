# cross-debug/86: ispc dispatch-builtins-bc Error 127 — cross clang wrapper lacks plain /bin/clang++

**Package:** `ispc-1.30.0.drv` (host=meteorlake, appears in chain: blender → openimagedenoise → embree → ispc)
**File:** `pkgs/by-name/is/ispc/package.nix`

## Symptom

```
/bin/bash: line 1: /nix/store/icqs6...-x86_64-unknown-linux-gnu-clang-wrapper-21.1.8/bin/clang++: No such file or directory
make[2]: *** [CMakeFiles/dispatch-builtins-bc.dir/build.make:75: share/ispc/builtins_dispatch.bc] Error 127
make: *** [Makefile:136: all] Error 2
```

The last 10 log lines also show a `-Wmaybe-uninitialized` **warning** (not `error:`) from
LLVM's DenseMap.h — that is noise. The real error is Error 127 earlier in the interleaved
parallel build output.

## Root Cause

**Pattern A** — build system assumes plain `clang++` in PATH / via absolute path.

ispc's cmake sets `CLANGPP_EXECUTABLE = ${llvmPackages.clang}/bin/clang++`.

`llvmPackages.clang` is nixpkgs' cc-wrapper around clang. In **cross builds**, the cc-wrapper
provides only **prefixed** names; plain names are omitted to prevent shadowing the build
platform's own compiler:

```
# Cross clang wrapper bin/:
x86_64-unknown-linux-gnu-clang
x86_64-unknown-linux-gnu-clang++
ld
(no plain clang or clang++)
```

```
# Native clang wrapper bin/:
clang
clang++
ld
(no prefixed names)
```

cmake's `dispatch-builtins-bc` custom command invokes `/…/bin/clang++` → "No such file or
directory" → Error 127 → `all` target fails.

## Why it looks like -Wmaybe-uninitialized

The parallel build log interleaves output from multiple targets. The `-Wmaybe-uninitialized`
warning (from `src/opt.cpp` via LLVM's DenseMap.h) is printed by a target that compiles
successfully. It appears in the last few log lines purely by timing; `make: all Error 2`
is caused by the `dispatch-builtins-bc` failure that happened concurrently.

## Fix

Use `llvmPackages.clang.cc` (raw LLVM binary) unconditionally for `CLANGPP_EXECUTABLE`.
The raw binary always has plain `/bin/clang++` in both native and cross contexts.
Add `CPATH = "${stdenv.cc.libc_dev}/include"` to the derivation `env` so the raw binary
can find standard C headers (`unistd.h`, `assert.h`) that the cc-wrapper normally injects
via `-isystem`.

In `pkgs/by-name/is/ispc/package.nix`:

```nix
let
  # Every cc-wrapper in pseudo-cross (native and cross) provides only prefixed names.
  # Raw LLVM binary always has plain /bin/clang++.
  clangForBc = llvmPackages.clang.cc;
in
stdenv.mkDerivation (finalAttrs: {
  ...
  env = lib.optionalAttrs (stdenv.cc.libc_dev or null != null) {
    CPATH = "${stdenv.cc.libc_dev}/include";
  };
  ...
  cmakeFlags = [
    ...
    (lib.cmakeFeature "CLANG_EXECUTABLE" "${clangForBc}/bin/clang")
    (lib.cmakeFeature "CLANGPP_EXECUTABLE" "${clangForBc}/bin/clang++")
    ...
  ];
```

## Why the conditional `hostPlatform != buildPlatform` approach didn't work

In pseudo-cross, ispc appears as a `nativeBuildInput` of embree (cross package).
`nativeBuildInputs` are resolved from `pkgsBuildBuild` (build=host=buildPlatform). In that
scope, `stdenv.hostPlatform == stdenv.buildPlatform` is TRUE → wrapper chosen → same Error 127.

The wrapper `x86_64-unknown-linux-gnu-clang-wrapper-21.1.8` (both "native" and cross) provides
only prefixed names in the pseudo-cross setup. The conditional can't escape this.

**Status: FIXED** (nixpkgs-patch `pkgs/by-name/is/ispc/package.nix`)
