# 22 — libosinfo: Vala requires introspection, introspection disabled in cross

**Package:** `libosinfo-x86_64-unknown-linux-gnu-1.12.0`  
**Commits:** `365f18d`, `594ca55` (two iterations)

## Symptom

```
meson.build:40:8: ERROR: Problem encountered: vala support was requested,
but introspection support is mandatory.
```

## Root cause

`libosinfo/meson.build` contains:

```python
gir = find_program('g-ir-scanner', required: get_option('enable-introspection'))
enable_introspection = gir.found() and not meson.is_cross_build()
...
enable_vapi = add_languages('vala', required: vapi_opt)
if enable_vapi and not enable_introspection:
    error('vala support was requested, but introspection support is mandatory.')
```

Meson auto-disables introspection in cross builds via `not meson.is_cross_build()`.
`vala` is in `nativeBuildInputs`, so `valac` is found and Vala is enabled by
default. But Vala requires introspection → hard error.

## Fix

Added `-Denable-vala=disabled` to `mesonFlags` for cross builds in
`pkgs/by-name/li/libosinfo/package.nix`:

```nix
mesonFlags = [
  "-Dwith-usb-ids-path=..."
  "-Dwith-pci-ids-path=..."
  "-Denable-gtk-doc=true"
] ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
  "-Denable-vala=disabled"
];
```

`-Denable-gtk-doc=true` doesn't need a cross guard — the meson.build already
gates gtk-doc on `not meson.is_cross_build()`.

### Iteration

First attempt used `"-Denable-vala=false"` → meson error "Value 'false' (of
type 'string') for option 'enable-vala' is not one of the choices. Possible
choices are: 'enabled', 'disabled', 'auto'." → corrected to `disabled`.

## Pattern

Non-pattern (Vala/introspection cross incompatibility). Common in GNOME
packages: introspection requires executing HOST binaries at build time, which
is impossible in a real cross build. Meson handles introspection correctly
but doesn't auto-disable Vala when it disables introspection.
