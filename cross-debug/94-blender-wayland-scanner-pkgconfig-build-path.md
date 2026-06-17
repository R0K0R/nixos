# cross-debug/94: blender — wayland-scanner pkg_check_modules fails in pseudo-cross

**Package:** `blender-x86_64-unknown-linux-gnu-5.1.1.drv`
**File:** `pkgs/by-name/bl/blender/package.nix`, `patches`

## Symptom

cmake configure fails with `set_and_warn_library_found("wayland-scanner" ...)` SEND_ERROR
(with `WITH_STRICT_BUILD_OPTIONS=true`), then later:

```
FATAL_ERROR "wayland-scanner" could not be found!
```

## Root Cause (two-part)

**Part 1 — binary not in PATH at all:**

`wayland-scanner` has three outputs: `out`, `bin`, `dev`. The default output (`out`) contains
only `share/`. The binary lives in the `bin` output, the `.pc` file in the `dev` output.

When `wayland-scanner` (bare, defaulting to `out`) is placed in `nativeBuildInputs`, the
setup hook adds `out/bin` to PATH — which doesn't exist. So `wayland-scanner` binary is
never in PATH during the build.

Fix: use `(lib.getBin wayland-scanner)` in `nativeBuildInputs`. `lib.getBin x = x.bin or x`
selects the `bin` output when present.

**Part 2 — .pc file not in PKG_CONFIG_PATH:**

Even with the binary in PATH, `pkg_check_modules(wayland-scanner wayland-scanner)` still
fails because the `.pc` file is in the `dev` output, which lands in `PKG_CONFIG_PATH_FOR_BUILD`
(nativeBuildInputs path), not `PKG_CONFIG_PATH` (what cmake's pkg_check_modules searches).

An earlier preConfigure attempt to compute the prefix from `which wayland-scanner` also
failed because: binary is in `-bin` output, while `.pc` file is in `-dev` output — they have
different nix store paths.

## Fix

Patch `build_files/cmake/platform/platform_unix.cmake` (via `patches`) to add `find_program`
fallbacks at both check points:

**Fix 1** — `wayland-scanner_FOUND` check (after `pkg_check_modules`):
```cmake
if(NOT wayland-scanner_FOUND)
  find_program(_ws_bin wayland-scanner)
  if(_ws_bin)
    set(wayland-scanner_FOUND TRUE)
  endif()
  unset(_ws_bin)
endif()
```

**Fix 2** — `WAYLAND_SCANNER` executable path (after `pkg_get_variable`):
```cmake
if(NOT WAYLAND_SCANNER)
  find_program(WAYLAND_SCANNER wayland-scanner)
endif()
```

Applied as `./wayland-scanner-fallback.patch` in the `patches` list under
`lib.optionals waylandSupport`.

`find_program` was tried first (with and without `NO_CMAKE_FIND_ROOT_PATH`) but both fail.
Root cause: nixpkgs's cmake setup hook adds nativeBuildInputs prefixes to
`NIXPKGS_CMAKE_PREFIX_PATH` (not `CMAKE_PREFIX_PATH`) and never populates `CMAKE_PROGRAM_PATH`.
cmake's `find_program` searches `CMAKE_PROGRAM_PATH` and `CMAKE_PREFIX_PATH/bin` but not
`NIXPKGS_CMAKE_PREFIX_PATH`, so nativeBuildInput binaries are invisible to it.

The reliable fix is `execute_process(COMMAND sh -c "which wayland-scanner" ...)` which
invokes the shell directly and uses the nix sandbox `PATH` unconditionally.
