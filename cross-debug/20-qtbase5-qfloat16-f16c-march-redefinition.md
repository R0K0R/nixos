# `qtbase-5.15.18`: qfloat16 F16C Redefinition with `-march=meteorlake`

**Package:** `qtbase-x86_64-unknown-linux-gnu-5.15.18`
**File:** `pkgs/development/libraries/qt-5/5.15/qtbase.patch.d/0013-qfloat16-f16c-march-redefinition.patch`

## Symptom

```
global/qfloat16_f16c.c:52:6: error: redefinition of 'void qFloatToFloat16_fast(quint16*, const float*, qsizetype)'
global/qfloat16.cpp:253:13: note: 'void qFloatToFloat16_fast(...)' previously defined here
```

Compile error (not link error), meaning both definitions are in the SAME translation unit.

## Root Cause

Compilation sequence when `QFLOAT16_INCLUDE_FAST` is defined (bootstrap build) AND
`-march=meteorlake` globally enables `__F16C__` BUT Qt configure's `QT_COMPILER_SUPPORTS(F16C)` = 0:

1. `qfloat16.cpp` takes the `#else` branch (no Qt-detected F16C support):
   - Compiles `static hasFastF16() { return false; }`
   - Compiles **static stubs** `qFloatToFloat16_fast` / `qFloatFromFloat16_fast` at lines 253, 258
2. At the bottom of `qfloat16.cpp`:
   ```cpp
   #ifdef QFLOAT16_INCLUDE_FAST
   #  include "qfloat16_f16c.c"
   #endif
   ```
3. `qfloat16_f16c.c` checks `QT_COMPILER_SUPPORTS_HERE(AVX)` = `__AVX__` = 1 (from march) → 
   defines `qFloatToFloat16_fast` (non-static) at line 52
4. **REDEFINITION**: static stub + non-static definition in same TU

The mismatch exists because:
- Qt configure ran on the BUILD machine (generic x86_64) → no F16C detected → `QT_COMPILER_SUPPORTS_F16C = 0`
- Actual compilation uses HOST compiler with `-march=meteorlake` → `__F16C__` globally true
- Qt configure result and compiler reality diverge

## Fix

Patch `qfloat16.cpp`: guard the static stubs with:
```cpp
#if !(defined(QFLOAT16_INCLUDE_FAST) && defined(__F16C__))
static void qFloatToFloat16_fast(...) { Q_UNREACHABLE(); }
static void qFloatFromFloat16_fast(...) { Q_UNREACHABLE(); }
#endif
```

When both conditions are true (bootstrap + global F16C), the stubs are suppressed and
`qfloat16_f16c.c` provides the only definition. The `hasFastF16()` still returns false
(since Qt didn't detect F16C), so the F16C path is never called — F16C functions are
compiled but dead. This is a minor performance loss in bootstrap code, not a runtime issue.

**Patch file format gotcha:** Blank lines inside a unified diff hunk MUST be written as
a space followed by a newline (` \n`), not a bare newline. A bare `\n` in the middle of
a hunk is interpreted as end-of-hunk, causing `patch: **** malformed patch at line N: }`.
Use Python to write the patch file directly to avoid editors stripping trailing spaces:
```python
with open('patch.patch', 'w') as f:
    f.write(' \n')  # blank context line
```

## Files

`pkgs/development/libraries/qt-5/5.15/qtbase.patch.d/0013-qfloat16-f16c-march-redefinition.patch`
Added to `pkgs/development/libraries/qt-5/5.15/default.nix` in `patches.qtbase`.

Actual source line numbers (qtbase-5.15.18, commit bebdfd5):
- Line 253: `qFloatToFloat16_fast` stub
- Line 258: `qFloatFromFloat16_fast` stub
- Patch hunk: `@@ -252,11 +252,13 @@` (covers blank line at 252 through `#endif` at 262)
