# blender: wayland-scanner defaults to `out` output, binary not in PATH

**Commit:** `6203ea501`
**File:** `pkgs/by-name/bl/blender/package.nix`

See also: `cross-debug/94-blender-wayland-scanner-pkgconfig-build-path.md`

## Symptom

cmake configure fails:

```
FATAL_ERROR "wayland-scanner" could not be found!
```

## Root Cause

`wayland-scanner` has three outputs: `out`, `bin`, `dev`.

- `out` — contains only `share/`; no binary
- `bin` — contains `bin/wayland-scanner`
- `dev` — contains `lib/pkgconfig/wayland-scanner.pc`

When `wayland-scanner` (bare, defaulting to `out`) is placed in `nativeBuildInputs`,
the setup hook adds `$out/bin` to PATH — but `$out/bin` does not exist. The binary
is never in PATH.

## Fix

```nix
# Before:
++ lib.optionals waylandSupport [ pkg-config wayland-scanner ]

# After:
++ lib.optionals waylandSupport [ pkg-config (lib.getBin wayland-scanner) ]
```

`lib.getBin x` returns `x.bin or x`, selecting the `bin` output when present.
