# 23 — Qt5 qtbase: qfloat16 F16C redefinition with -march=meteorlake

**Package:** `qtbase-x86_64-unknown-linux-gnu-5.15.18`  
**Commit:** `9eb1fdf` (overlay)

## Symptom

```
global/qfloat16_f16c.c:52:6: error: redefinition of 'void qFloatToFloat16_fast(quint16*, const float*, qsizetype)'
global/qfloat16_f16c.c:68:6: error: redefinition of 'void qFloatFromFloat16_fast(float*, const quint16*, qsizetype)'
```

## Root cause

`src/corelib/global/qfloat16.cpp` has two separate mechanisms for F16C:

**At configure time** Qt checks for `__F16C__` support and sets
`QT_COMPILER_SUPPORTS_F16C`. In pseudo-cross, Qt's configure runs with the
native BUILD compiler (no `-march=meteorlake`), so `QT_COMPILER_SUPPORTS_F16C`
= 0.

**At compile time**, the HOST compiler `x86_64-unknown-linux-gnu-gcc` receives
`-march=meteorlake` via `NIX_CFLAGS_COMPILE`. Meteorlake supports F16C, so
the compiler defines `__F16C__`.

This mismatch triggers the conflict:

```cpp
// Line 201: #if QT_COMPILER_SUPPORTS(F16C)  → FALSE (configure said no F16C)
// Lines 248-261 #else branch → STATIC STUBS compiled:
static void qFloatToFloat16_fast(...) { Q_UNREACHABLE(); }
static void qFloatFromFloat16_fast(...) { Q_UNREACHABLE(); }
// Line 262: #endif

// Line 304: #ifdef QFLOAT16_INCLUDE_FAST  → TRUE (always in CXXFLAGS)
// Line 305:   #include "qfloat16_f16c.c"  → NON-STATIC definitions:
void qFloatToFloat16_fast(...)  { /* F16C impl */ }  // CONFLICT with static above
void qFloatFromFloat16_fast(...) { ... }
```

`-DQFLOAT16_INCLUDE_FAST` is always in Qt's CXXFLAGS; it means "include the
F16C implementation inline rather than as a separate object file." With
`QT_COMPILER_SUPPORTS(F16C)` = 0 (stubs compiled) but `QFLOAT16_INCLUDE_FAST`
defined (F16C included) → same symbols defined twice → error.

## Fix (overlay `default.nix`)

Extended the existing qtbase5 override to add a `postPatch` that guards the
`#include "qfloat16_f16c.c"` with `QT_COMPILER_SUPPORTS(F16C)`:

```bash
sed -i '/^#include "qfloat16tables.cpp"$/{n; s/#ifdef QFLOAT16_INCLUDE_FAST/#if defined(QFLOAT16_INCLUDE_FAST) \&\& QT_COMPILER_SUPPORTS(F16C)/}' src/corelib/global/qfloat16.cpp
```

The sed targets the second `#ifdef QFLOAT16_INCLUDE_FAST` (line 304) by
anchoring on its unique preceding line (`#include "qfloat16tables.cpp"` at
line 303), leaving the first instance (line 210, inside the F16C branch for
the `static` linkage dance) untouched.

## Pattern

Pattern F (ISA namespace / -march collision, cross-debug/90). The fundamental
fix is F6 (cc-wrapper `-march` dedup from the pseudo-cross plan v2), which
would prevent `-march=meteorlake` from overriding per-file `-march` flags.
This is a per-package workaround that restores Qt5's intended behavior.

Qt5 is EOL; upstream fix is not expected.
