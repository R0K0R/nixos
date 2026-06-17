# 87 — openshadinglanguage: LLVM_BC_GENERATOR needs cc-wrapper with stdlib includes

## Pattern
Pattern A (see 00-pseudo-cross-fundamental-patterns.md): build system receives a path to a tool
that is expected to be callable as a plain binary name, but the nix cc-wrapper in pseudo-cross
only provides the prefixed name.

## Symptom

```
error: builder for '.../openshadinglanguage-x86_64-unknown-linux-gnu-1.15.3.0.drv' failed
```

OSL's cmake compiles shader source files to LLVM bitcode using `$LLVM_BC_GENERATOR`. Two
failure modes were encountered when setting this flag:

**Mode 1 — exit 127 (binary not found):**
```
bash: clang++: command not found
```
Caused by pointing at the cc-wrapper's `bin/clang++`, which doesn't exist in pseudo-cross.

**Mode 2 — 'cstddef' file not found (stdlib headers missing):**
```
fatal error: 'cstddef' file not found
fatal error: 'cmath' file not found
```
Caused by pointing at `clang.cc` (raw LLVM binary), which has `bin/clang++` but no
`-isystem` paths for nixpkgs' C++ stdlib.

## Root Cause

In a pseudo-cross build, `llvmPackages_19.clang` is the cc-wrapper that:
- Runs on the build machine
- Targets the host platform (meteorlake)
- **Only provides the prefixed binary**: `bin/x86_64-unknown-linux-gnu-clang++`
- Does NOT provide: `bin/clang++`

`llvmPackages_19.clang.cc` is the raw LLVM clang binary that:
- Has `bin/clang++` (plain name, always)
- Does NOT inject `-isystem` paths for the C++ stdlib
- Cannot find `<cstddef>`, `<cmath>` etc. in the nix sandbox

cmake uses `LLVM_BC_GENERATOR` as a full path, so the prefix in the filename is irrelevant.

## Fix

In OSL's package scope, `llvmPackages_19.clang` resolves to the **BUILD-platform** clang
wrapper (`clang-wrapper-19.1.7`), not the HOST-targeting wrapper. This wrapper:
- Has `bin/clang++` (plain name, exists)
- Injects C++ stdlib `-isystem` paths
- Does NOT inject a host-specific `-march=` flag → generates portable x86_64 bitcode

```nix
# Correct — BUILD platform wrapper has plain bin/clang++ with stdlib includes:
"-DLLVM_BC_GENERATOR=${clang}/bin/clang++"

# FAILED (mode 1 — binary doesn't exist in HOST-targeting wrapper):
"-DLLVM_BC_GENERATOR=${clang}/bin/clang++"  # (if clang resolved to HOST wrapper)

# FAILED (mode 2 — stdlib headers missing):
"-DLLVM_BC_GENERATOR=${clang.cc}/bin/clang++"  # raw binary, no -isystem paths

# FAILED (mode 3 — prefixed name doesn't exist in BUILD wrapper):
"-DLLVM_BC_GENERATOR=${clang}/bin/${stdenv.hostPlatform.config}-clang++"
```

The resolution of `clang` matters: if it's the BUILD wrapper use `bin/clang++`; if it's
the HOST-targeting wrapper use `bin/${stdenv.hostPlatform.config}-clang++`.

Applied in: `pkgs/by-name/op/openshadinglanguage/package.nix`

**Note:** `python3Packages` must remain in OSL's formal argument list as `python3Packages ? null`.
`python-packages.nix` defines `python3Packages.openshadinglanguage` as:
```nix
toPythonModule (pkgs.openshadinglanguage.override { python3Packages = self; })
```
Removing the formal arg causes "unexpected argument 'python3Packages'" at evaluation time.

## Bonus: Python cross mismatch also removed

OSL's `python3Packages.pybind11` buildInput and `python3Packages.openimageio`
propagatedBuildInput trigger the same pybind11 cmake hook Python path mismatch documented for
openimageio (Pattern A variant: cmake `find_package(Python3)` mixing native PYTHON_EXECUTABLE
with cross PYTHON_INCLUDE_DIR). Since blender uses OSL as a pure C++ shading library, Python
bindings are unused:

```nix
"-DUSE_PYTHON=OFF"
```

and `python3Packages.{pybind11,openimageio}` removed from buildInputs/propagatedBuildInputs.
See also cross-debug/92 for the `find_package(Python3)` docs build issue.
