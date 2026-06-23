# 13 — ispc: cmake can't find `clang++` for LLVM bitcode compilation

## Symptom

```
CMake Error: Could not find CMAKE_CXX_COMPILER: clang++
```
or:
```
CLANGPP_EXECUTABLE not found
```

ispc needs `clang++` during the build phase to compile LLVM bitcode builtins.

## Root cause (two iterations)

### Root cause 1: using HOST cross-wrapper instead of BUILD-native clang

ispc's cmake sets `CLANGPP_EXECUTABLE` from `llvmPackages.clang`. In
pseudo-cross, `llvmPackages.clang` is the HOST cross-wrapper, which only
exposes `x86_64-unknown-linux-gnu-clang++` (the target-prefixed name) — not
plain `clang++`. cmake's `find_program(clang++)` fails.

**Round 1 fix:** Point cmake at `buildPackages.llvmPackages.clang` (the
BUILD-native clang) which has plain `clang++`. (commit `c80c110f2`)

### Root cause 2: buildPackages in pseudo-cross still resolves to cross-wrapper

In pseudo-cross, `buildPackages.llvmPackages` aliases to the same cross-wrapper
as the HOST. The wrapper's binary name still has the target prefix.

**Round 2 fix:** Use `llvmPackages.clang.cc` — the **unwrapped** clang binary
(the actual compiler executable, not the cc-wrapper shell script). The unwrapped
binary always has plain `clang` and `clang++` regardless of what prefix the
wrapper uses. (commit `990c6fe7b`)

```nix
CLANG_EXECUTABLE   = "${llvmPackages.clang.cc}/bin/clang";
CLANGPP_EXECUTABLE = "${llvmPackages.clang.cc}/bin/clang++";
```

## Cross-debug category

**Pattern A2 (clang plain name):** The cross cc-wrapper only exposes
`${targetPrefix}clang++`; code that searches for plain `clang++` fails.
The fundamental fix (F2) adds plain-name symlinks in the cc-wrapper itself.
The per-package fix uses `.cc` (the unwrapped binary) which always has plain names.

## nixpkgs-contrib commits

- `c80c110f2` — round 1 (buildPackages.llvmPackages.clang)
- `990c6fe7b` — round 2 (llvmPackages.clang.cc unwrapped)
