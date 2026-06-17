# cross-debug/90: embree — ISA namespace collision + BVHN<4> non-instantiation

**Package:** `embree-4.4.0.drv` (host=meteorlake)
**Files:** `common/cmake/gnu.cmake`, `common/sys/sysinfo.h`, `CMakeLists.txt`, `kernels/bvh/bvh.cpp`

## Symptoms

Two distinct classes of linker errors, both from the same root trigger:

**Class 1 — ISA namespace collision:**
```
ld.bfd: bvh4_factory.cpp.o: undefined reference to `embree::sse42::BVH4Triangle4iIntersector1Moeller()'
ld.bfd: bvh4_factory.cpp.o: undefined reference to `embree::avx::BVH4Triangle4vIntersector1Moeller()'
... (hundreds of similar errors for sse42::* and avx::* symbols)
```

**Class 2 — BVHN<4> non-instantiation:**
```
ld.bfd: bvh_builder_twolevel.cpp.o: undefined reference to `embree::BVHN<4>::preBuild(...)'
ld.bfd: bvh_builder_subdiv.cpp.o: undefined reference to `embree::BVHN<4>::set(...)'
... (dozens of similar errors)
```

## Root Trigger: `-march=meteorlake` injected into all compilations

In pseudo-cross builds, the nixpkgs cross GCC wrapper appends `-march=meteorlake`
to `NIX_CFLAGS_COMPILE` for every compilation. This predefines `__AVX2__` (and
`__AVX__`, etc.) in all compilation units — including the ISA-specific static
libs (`embree_sse42`, `embree_avx`) that are supposed to compile WITHOUT AVX2.

## Root Cause: Class 1 — ISA namespace collision

embree uses a preprocessor macro `isa` to select the C++ namespace for each
ISA compilation target. The selection is in `common/sys/sysinfo.h`:

```cpp
#elif defined (__AVX2__)
#  define isa avx2
...
#elif defined (__SSE4_2__)
#  define isa sse42
```

It checks the HIGHEST defined ISA macro. `namespace embree { namespace isa { } }`
in each source file becomes `namespace embree { namespace avx2 { } }` when
`__AVX2__` is defined.

On x86_64, `common/cmake/gnu.cmake` sets per-ISA compile flags via:
```cmake
ELSE ()
  _SET_IF_EMPTY(FLAGS_SSE42 "-msse4.2")
  _SET_IF_EMPTY(FLAGS_AVX   "-mavx")
  _SET_IF_EMPTY(FLAGS_AVX2  "-mf16c -mavx2 -mfma -mlzcnt -mbmi -mbmi2")
  ...
ENDIF ()
```

`-msse4.2` does not undefine `__AVX2__` — it's additive. With the ambient
`-march=meteorlake` already defining `__AVX2__`, the SSE4.2 and AVX static libs
both compile all their symbols into the `embree::avx2::` namespace instead of
`embree::sse42::` / `embree::avx::`.

The factory code (`bvh4_factory.cpp`) references all ISA namespaces at link
time → undefined references for `sse42::*` and `avx::*`.

## Root Cause: Class 2 — BVHN<4> non-instantiation

`kernels/bvh/bvh.cpp` contains the out-of-line definitions of all `BVHN<N>`
methods and their explicit template instantiations at the bottom:

```cpp
#if defined(__AVX__)
  template class BVHN<8>;
#endif
#if !defined(__AVX__) || !defined(EMBREE_TARGET_SSE2) && !defined(EMBREE_TARGET_SSE42) || defined(__aarch64__)
  template class BVHN<4>;
#endif
```

The condition for `BVHN<4>` instantiation evaluates to:

```
!defined(__AVX__)                           → false  (meteorlake defines __AVX__)
|| !defined(EMBREE_TARGET_SSE2) && ...      → false && false  (see below)
|| defined(__aarch64__)                     → false
= false
```

The middle clause is false because `ADD_DEFINITIONS(-DEMBREE_TARGET_SSE2)` and
`ADD_DEFINITIONS(-DEMBREE_TARGET_SSE42)` are called globally in the top-level
`CMakeLists.txt` whenever `EMBREE_ISA_SSE2=ON` and `EMBREE_ISA_SSE42=ON`
(which is the default). `ADD_DEFINITIONS` applies to ALL cmake targets, including
the main `embree` shared library where `bvh.cpp` is compiled. So
`EMBREE_TARGET_SSE2` and `EMBREE_TARGET_SSE42` are defined in every compilation
unit, making both `!defined(EMBREE_TARGET_SSE*)` clauses false.

Result: `BVHN<4>` is never explicitly instantiated anywhere. Callers in the
same link unit get undefined references at link time.

## Fix Attempts (Failed)

### Attempt 1: `-march=<isa>` override in FLAGS_SSE42

Added `-march=nehalem` to `FLAGS_SSE42` etc. Failed: the nixpkgs GCC cross-wrapper
appends `NIX_CFLAGS_COMPILE` (including `-march=meteorlake`) AFTER cmake's
`COMPILE_FLAGS`. GCC uses the last `-march=` on the command line, so the wrapper
always wins.

### Attempt 2: `-U` undefines in gnu.cmake (ARM block — wrong path)

```nix
sed -i \
  's|^  SET(FLAGS_SSE42 .*|  SET(FLAGS_SSE42 "-U__AVX2__ ...")|;
   ...' \
  common/cmake/gnu.cmake
```

Failed: the sed patterns match lines inside `IF (EMBREE_ARM)` which is never
entered on x86_64. The x86_64 path uses `_SET_IF_EMPTY(...)` in the `ELSE()`
block, which the sed did not touch. The patches were no-ops.

(Note: `-U` undefines are the correct mechanism — GCC processes them after
all implicit predefined macros from `-march=` and they cannot be overridden
by a subsequent `-march=`. The approach was sound; only the target lines were wrong.)

## Correct Fix: Disable lower ISA targets via cmake flags

```nix
cmakeFlags = [
  ...
  "-DEMBREE_ISA_SSE2=OFF"
  "-DEMBREE_ISA_SSE42=OFF"
  "-DEMBREE_ISA_AVX=OFF"
  "-DEMBREE_ISA_AVX512=OFF"
];
```

This fixes both classes simultaneously:

**Class 1:** With SSE2/SSE42/AVX disabled, the `embree_sse42.a` and `embree_avx.a`
static libs are never built. No ISA namespace collision possible.

**Class 2:** With SSE2/SSE42 disabled, the `ADD_DEFINITIONS(-DEMBREE_TARGET_SSE2)`
and `ADD_DEFINITIONS(-DEMBREE_TARGET_SSE42)` blocks are skipped. `EMBREE_TARGET_SSE2`
and `EMBREE_TARGET_SSE42` are no longer globally defined. The bvh.cpp condition
becomes `false || (true && true) || false` = **true** → `BVHN<4>` is instantiated.

**Runtime impact:** Meteor Lake always supports AVX2. Disabling SSE2/SSE42/AVX
dispatch targets loses nothing at runtime — those code paths would never have
been selected on this CPU anyway.

Applied in `pkgs/by-name/em/embree/package.nix` `cmakeFlags`.

## Upstream Fix

The `BVHN<4>` condition in `bvh.cpp` should not rely on `EMBREE_TARGET_SSE*` to
determine whether to instantiate `BVHN<4>` — those defines were added for an
unrelated purpose (ISA dispatch hints) and have become a surprising precondition
for a fundamental template instantiation. The condition should either not gate
on `EMBREE_TARGET_*`, or the instantiation should be unconditional when AVX is
the lowest ISA.

For `gnu.cmake`, the `_SET_IF_EMPTY(FLAGS_SSE42 "-msse4.2")` path should use
`-U` undefines to strip higher-ISA macros that may be ambient from the build
environment's `-march=` setting.
