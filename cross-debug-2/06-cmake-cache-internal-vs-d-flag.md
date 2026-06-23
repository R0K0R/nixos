# 06 — cmake: `CACHE INTERNAL` overwrites `-D` flag values

## Observation

When jasper's CMakeLists.txt does:

```cmake
set(JAS_STDC_VERSION "0L" CACHE INTERNAL "The value of __STDC_VERSION__.")
```

…passing `-DJAS_STDC_VERSION=201710L` on the cmake command line does NOT prevent
the variable from being set to `"0L"`.

## cmake documentation vs. reality

cmake docs state that `set(VAR value CACHE type doc)` without `FORCE` only sets the
cache if the variable is not already there. `-D` flags pre-populate the cache before
CMakeLists.txt runs, so they should survive a non-FORCE cache set.

In practice, with the cmake version current in nixpkgs (3.31+), `CACHE INTERNAL`
type appears to always write the value, behaving like an implicit `FORCE`. This
differs from `CACHE STRING` or `CACHE BOOL` behavior.

## Interaction with the F11 preload

The nixpkgs cmake setup hook (F11) generates a preload file via `CMAKE_PROJECT_INCLUDE`
that emits:
```cmake
set(JAS_STDC_VERSION "201710L" CACHE STRING "" FORCE)
```

This runs right after `project()` at line 54 — well before line 443 where the sentinel
is set. The FORCE write should stick. Yet the build still failed, suggesting the
subsequent `CACHE INTERNAL` set at line 443 overwrote it.

## Implication

For packages that use `set(VAR sentinel CACHE INTERNAL ...)` to detect missing
command-line input, the reliable fix is to patch the sentinel value in the source
rather than supplying a `-D` flag. The `-D` / preload approach is unreliable with
`CACHE INTERNAL`.

## See also

- Fix #03 (jasper) — applied postPatch to change the sentinel from `"0L"` to `"201710L"`
