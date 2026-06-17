# cross-debug/91: embree — BVHN<4> hypothesis: @PLT / STV_HIDDEN / ld.bfd (DISPROVEN)

**Package:** `embree-4.4.0.drv` (host=meteorlake)
**Status:** Root cause hypothesis disproven. Actual fix documented in cross-debug/90.

## Hypothesis

When `BVHN<4>::preBuild` etc. produced undefined references despite `bvh.cpp`
being in the same link unit, the initial theory was a `ld.bfd` @PLT / STV_HIDDEN
mismatch:

- `-fvisibility=hidden` (set globally in `CMakeLists.txt`) causes GCC to mark
  the `BVHN<4>` symbols as `STV_HIDDEN` in `bvh.cpp.o`
- Callers in the same link unit may still emit `@PLT` (R_X86_64_PLT32)
  relocations when the definition was not visible across compilation units
- `ld.bfd` refuses to resolve an `@PLT` relocation against a `STV_HIDDEN` symbol
  (since PLT entries are for inter-DSO calls and hidden symbols can't cross DSO
  boundaries); `lld` silently converts these to direct calls

This is a real `ld.bfd` behavior (and a real pattern in cross builds — see
cross-debug/78 for a vtable/typeinfo variant), so it was a reasonable hypothesis.

## Disproof

Added to `postPatch`:
```nix
sed -i 's|-fvisibility=hidden||g; s|-fvisibility-inlines-hidden||g' \
  CMakeLists.txt
```

The rebuild produced identical `BVHN<4>` undefined reference errors. Removing
`-fvisibility=hidden` had zero effect on the failure.

## Actual Root Cause

The `BVHN<4>` explicit instantiation in `bvh.cpp` is guarded by a preprocessor
condition that evaluates to false when both `__AVX__` (from `-march=meteorlake`)
and `EMBREE_TARGET_SSE2`/`EMBREE_TARGET_SSE42` (from global `ADD_DEFINITIONS`)
are defined — which is always true in this build. `BVHN<4>` is never instantiated
anywhere.

See cross-debug/90 for full analysis and the correct fix.

## Note on the -fvisibility=hidden sed

The `sed -i 's|-fvisibility=hidden||g'` line was present in `package.nix` during
this investigation. It is harmless and was left in place briefly, then removed
when the ISA-disable cmake flags made it unnecessary. The version-script
(`export.linux.map`) already controls exported symbols via `local: *`, so
removing `-fvisibility=hidden` is correct even if unnecessary for this specific bug.
