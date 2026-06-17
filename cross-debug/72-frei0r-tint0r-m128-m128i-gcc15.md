# cross-debug/72: frei0r-plugins tint0r.c __m128/__m128i hard error on GCC 15

## Problem

`frei0r-plugins-x86_64-unknown-linux-gnu-2.5.1` fails to build on GCC 15:

```
/build/source/src/filter/tint0r/tint0r.c:195:9: error:
  incompatible types when assigning to type '__m128' from type '__m128i'
/build/source/src/filter/tint0r/tint0r.c:207:11: error:
  incompatible types when assigning to type '__m128' from type '__m128i'
/build/source/src/filter/tint0r/tint0r.c:212:43: error:
  incompatible type for argument 1 of '_mm_packus_epi32'
...
make[2]: *** [src/filter/tint0r/CMakeFiles/tint0r.dir/build.make:79: ...]
  Error 1
```

## Root cause

`src/filter/tint0r/tint0r.c` declares loop variables as `__m128` (float vector)
but assigns them from and passes them to `__m128i` (integer vector) SSE
intrinsics (`_mm_cvtepu8_epi32`, `_mm_srli_si128`, `_mm_packus_epi32`,
`_mm_storeu_si128`). The code is using float-typed registers as raw 128-bit
containers for integer operations, a pattern that older GCC accepted.

GCC 15 made this a **hard type error** even in C17/gnu17 mode — it is not a
warning demoted to error; it is a genuine incompatible-type assignment that can
no longer be silenced with `-Wno-*` or `-std=gnu17`.

Passing `-std=gnu17` via `NIX_CFLAGS_COMPILE` is visible in the build log but
has no effect on the errors.

## Fix

Exclude the tint0r filter from the frei0r cmake build entirely.  The other
~100 filters build cleanly; tint0r provides only a minor "tint" colour effect.

In `hosts/galaxybook4-pro360/default.nix` (inside the combined xapian overlay):

```nix
frei0r = prev.frei0r.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    sed -i '/tint0r/d' src/filter/CMakeLists.txt
  '';
});
```

## Files

- `hosts/galaxybook4-pro360/default.nix` — overlay that drops the tint0r subdir
- `pkgs/by-name/fr/frei0r/package.nix` — upstream package (no fix needed there)
