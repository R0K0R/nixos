# blender: wayland-scanner required but not found in pseudo-cross

**Commit:** `(this session)`
**File:** `pkgs/by-name/bl/blender/package.nix`

## Symptom

```
-- Checking for module 'wayland-scanner'
--   No package 'wayland-scanner' found
CMake Error at build_files/cmake/macros.cmake:1358 (message):
  wayland-scanner required but not found
Call Stack (most recent call first):
  build_files/cmake/platform/platform_unix.cmake:758 (set_and_warn_library_found)
  CMakeLists.txt:1589 (include)
```

## Root Cause

cmake's `FindPkgConfig.cmake` discovers the pkg-config executable by
checking the `PKG_CONFIG` environment variable first, then searching PATH.

In pseudo-cross with F4 (strictDeps relax), both BUILD and HOST package setup
hooks are sourced.  The HOST-platform pkg-config-wrapper setup hook sets
`PKG_CONFIG=x86_64-unknown-linux-gnu-pkg-config`.  cmake's `FindPkgConfig`
picks this up and uses the HOST pkg-config wrapper.

The build log confirms:
```
-- Found PkgConfig: /nix/store/.../x86_64-unknown-linux-gnu-pkg-config-wrapper-0.29.2/bin/x86_64-unknown-linux-gnu-pkg-config
```

This HOST wrapper only searches `PKG_CONFIG_PATH` (HOST-platform pkgconfig
dirs).  `wayland-scanner.pc` lives in the BUILD-platform wayland-scanner
store path, which is only in `PKG_CONFIG_PATH_FOR_BUILD`.  So
`pkg_check_modules(WAYLAND_SCANNER wayland-scanner)` returns NOT_FOUND.

`WITH_STRICT_BUILD_OPTIONS=ON` (passed by the nixpkgs blender package)
escalates the missing-tool warning to a `FATAL_ERROR`.

Note: the `wayland-scanner` binary IS in PATH (it's in nativeBuildInputs,
and F5's CMAKE_PROGRAM_PATH mechanism makes it findable by `find_program`).
The failure is specifically in `pkg_check_modules`, not `find_program`.

## Why pkg_check_modules isn't fixable via preload

The F11 cmake preload sets vars as `CACHE STRING FORCE`.  But
`pkg_check_modules` uses `CACHE INTERNAL` to write its result variables
(e.g. `WAYLAND_SCANNER_FOUND`), which also implies FORCE.  So preload-set
vars are always overridden by pkg_check_modules.

## Why plain PKG_CONFIG_PATH export doesn't work

The nixpkgs pkg-config-wrapper replaces `PKG_CONFIG_PATH` with a salt-keyed
variable at exec time:
```bash
PKG_CONFIG_PATH=$PKG_CONFIG_PATH_abc123 exec /nix/store/.../pkg-config "$@"
```
Exporting `PKG_CONFIG_PATH` in preConfigure is silently ignored — the wrapper
replaces it unconditionally.

## Fix

In `preConfigure`, when `stdenv.isPseudoCross`:
1. Locate the BUILD wayland-scanner via `command -v wayland-scanner` (it's in
   PATH from nativeBuildInputs)
2. Find the HOST pkg-config wrapper (`x86_64-unknown-linux-gnu-pkg-config`)
3. Read the wrapper script to extract the actual salt variable name via
   `grep -oE 'PKG_CONFIG_PATH_[A-Za-z0-9_]+'`
4. Prepend the BUILD wayland-scanner pkgconfig dir to that salt-keyed variable
   directly, bypassing the wrapper's replacement logic

```bash
ws_bin="$(command -v wayland-scanner || true)"
if [ -n "$ws_bin" ]; then
  ws_prefix="$(dirname "$(dirname "$ws_bin")")"
  ws_pcdir="$ws_prefix/lib/pkgconfig"
  host_pc_bin="$(command -v x86_64-unknown-linux-gnu-pkg-config 2>/dev/null || true)"
  if [ -n "$host_pc_bin" ]; then
    pc_salt_var="$(grep -oE 'PKG_CONFIG_PATH_[A-Za-z0-9_]+' "$host_pc_bin" 2>/dev/null | head -1 || true)"
    if [ -n "$pc_salt_var" ]; then
      eval "export $pc_salt_var=\"\$ws_pcdir:\${$pc_salt_var}\""
    fi
  fi
fi
```

After this, when the HOST wrapper runs `PKG_CONFIG_PATH=$PKG_CONFIG_PATH_abc123
exec pkg-config wayland-scanner`, the underlying pkg-config sees the BUILD
wayland-scanner's pkgconfig dir and returns it as found.

cmake then finds the BUILD-platform binary at
`${WAYLAND_SCANNER_wayland-scanner_PREFIX}/bin/wayland-scanner`, which is
correct — wayland-scanner is a BUILD-time code generator that must execute on
the BUILD machine.

## Pattern

Pattern E (cmake pkg_check_modules for BUILD-time tool falls through HOST
pkg-config wrapper).  Related to cross-debug/94.

The general F5 fix (cmake `CMAKE_PROGRAM_PATH`) covers `find_program` calls
but NOT `pkg_check_modules` calls.  A future infrastructure fix would reset
`PKG_CONFIG` to the plain BUILD pkg-config before cmake configure, but only
for `pkg_check_modules` calls targeting BUILD tools — which cmake cannot
distinguish from HOST library checks without per-package annotation.

This per-package preConfigure approach is the correct scalpel: it adds only
the BUILD wayland-scanner to PKG_CONFIG_PATH, not the entire BUILD pkgconfig
tree, so HOST library checks remain unaffected.
