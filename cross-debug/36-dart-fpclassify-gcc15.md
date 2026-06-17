# Dart source build: `fpclassify` undeclared (GCC 15)

**Package:** `dart-x86_64-unknown-linux-gnu-3.11.4` (source build)
**File:** `pkgs/development/compilers/dart/source/default.nix`

## Symptom

```
../../runtime/vm/simulator_riscv.cc:2995:11: error: 'fpclassify' was not
declared in this scope; did you mean 'std::fpclassify'?
 2995 |   switch (fpclassify(x)) {
```

## Root Cause

GCC 15 changed C++ header behavior: `fpclassify` (from `<cmath>`) is no longer
injected into the global namespace. Code must use `std::fpclassify`.

`simulator_riscv.cc` is Dart's RISC-V CPU simulator. It is compiled on all
platforms (including x86_64) and uses bare `fpclassify(x)` in several
`switch` statements.

The dart source package already has `gcc13.patch` and `gcc15-close-range.patch`
but no patch for this `<cmath>` namespace change.

## Fix

Add a `sed` to `postPatch` to qualify `fpclassify` with `std::`:

```nix
postPatch = ''
  ...
  sed --in-place 's/\bfpclassify(/std::fpclassify(/g' runtime/vm/simulator_riscv.cc
'';
```

The `\b` word-boundary prevents double-qualifying any already-prefixed calls.

**Status: FIXED**
