# 21 — dart: fpclassify/signbit undeclared in simulator_riscv.cc (GCC 15)

**Package:** `dart-x86_64-unknown-linux-gnu-3.11.4` (source build)  
**Commits:** `4a1ee32`, `c14e2f1`, `5f87f92`, `66ef10e` (four iterations)

## Symptom

```
../../runtime/vm/simulator_riscv.cc:2995:11: error: 'fpclassify' was not declared in this scope; did you mean 'std::fpclassify'?
../../runtime/vm/simulator_riscv.cc:3074:11: error: 'fpclassify' was not declared in this scope; did you mean 'std::fpclassify'?
```

Second iteration (after fixing fpclassify):

```
../../runtime/vm/simulator_riscv.cc:2897:14: error: 'signbit' was not declared in this scope; did you mean 'std::signbit'?
../../runtime/vm/simulator_riscv.cc:2923:14: error: 'signbit' was not declared in this scope; did you mean 'std::signbit'?
```

## Root cause

GCC 15 stopped injecting C math functions (`fpclassify`, `signbit`, `isnan`,
`isinf`, `isfinite`) into the global namespace when included via C++ headers
(`<cmath>` instead of `<math.h>`). Code using unqualified `fpclassify(x)`
must be updated to `std::fpclassify(x)`.

This is cross-debug/36+38 from the pattern catalogue (GCC 15 strictness,
non-pattern — affects native builds too but native dart uses the prebuilt
binary).

## Fix

Added a `sed` loop in `postPatch` of `pkgs/development/compilers/dart/source/default.nix`:

```nix
for func in fpclassify signbit isnan isinf isfinite; do
  sed --in-place -E "s/(^|[^:])''${func}\(/\1std::''${func}(/g" runtime/vm/simulator_riscv.cc
done
```

The regex `(^|[^:])func\(` matches `func(` at line start or preceded by any
non-colon character — this avoids double-qualifying already-present
`std::func(` calls (which are preceded by `:`).

### Iteration history

1. Used `perl -i -pe` with negative lookbehind → failed: `perl` not in
   `nativeBuildInputs` → exit code 127.
2. Switched to `sed -E`, but only covered `fpclassify` → `signbit` errors
   surfaced next.
3. Widened to loop over all five GCC 15 math functions, but used `${func}`
   in Nix `''` string → Nix tried to interpolate `func` as a Nix variable →
   "undefined variable 'func'".
4. Fixed Nix escape: `''${func}` in a `''` string produces literal `${func}`
   in the shell string → shell variable expansion works correctly in the loop.

## Notes

`dart` (default.nix) is a prebuilt binary download. The source build
(`source/default.nix`) is invoked only for cross-compilation targets. The
existing `gcc13.patch` handles `<cstdint>` missing; this extends the
pattern to the GCC 15 math namespace change.
