# dart: `isnan`, `signbit` undeclared identifier (GCC 15 global namespace removal)

**Package:** `dart-x86_64-unknown-linux-gnu-3.11.4`
**File:** `pkgs/development/compilers/dart/source/default.nix`

## Symptom

```
runtime/vm/simulator_riscv.cc: error: 'isnan' was not declared in this scope
runtime/vm/simulator_riscv.cc: error: 'signbit' was not declared in this scope
```

(Same file and same root cause as the earlier `fpclassify` issue — doc 36.)

## Root Cause

GCC 15 removed `fpclassify`, `isnan`, and `signbit` from the global C++ namespace
in `<cmath>`. They must now be qualified as `std::isnan`, `std::signbit`, etc.

`runtime/vm/simulator_riscv.cc` used all three without the `std::` prefix, and
the RISC-V simulator is compiled on all platforms (not just RISC-V).

The `fpclassify` fix (doc 36) was applied in the previous build, but `isnan` and
`signbit` were missed.

## Fix

Added two more `sed` lines to `postPatch` in `dart/source/default.nix`,
alongside the existing `fpclassify` fix:

```nix
sed --in-place 's/\bisnan(/std::isnan(/g' runtime/vm/simulator_riscv.cc
sed --in-place 's/\bsignbit(/std::signbit(/g' runtime/vm/simulator_riscv.cc
```

These three lines now sit together in the postPatch block:

```nix
sed --in-place 's/\bfpclassify(/std::fpclassify(/g' runtime/vm/simulator_riscv.cc
sed --in-place 's/\bisnan(/std::isnan(/g' runtime/vm/simulator_riscv.cc
sed --in-place 's/\bsignbit(/std::signbit(/g' runtime/vm/simulator_riscv.cc
```
