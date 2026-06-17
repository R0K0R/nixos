# `libqmi`: `gtk_doc` Build Fails — `gi-docgen` Needs BUILD-Machine `pkg-config`

**Package:** `libqmi-x86_64-unknown-linux-gnu-1.38.0`
**File:** `pkgs/by-name/li/libqmi/package.nix`

## Symptom

```
Did not find pkg-config by name 'pkg-config'
Found pkg-config: NO
...
Build-time dependency gi-docgen found: NO
docs/reference/libqmi-glib/meson.build:19:0: ERROR: Dependency lookup for gi-docgen with method 'pkgconfig' failed: Pkg-config for machine build machine not found. Giving up.
```

## Root Cause

The `withIntrospection` condition:
```nix
withIntrospection ?
  lib.meta.availableOn stdenv.hostPlatform gobject-introspection
  && stdenv.hostPlatform.emulatorAvailable buildPackages,
```

In the pseudo-cross meteorlake build, `mesonEmulatorHook` adds QEMU as the `exe_wrapper`,
making `stdenv.hostPlatform.emulatorAvailable buildPackages = true`. So `withIntrospection = true`,
which enables `gtk_doc = true`.

`gtk_doc` requires `gi-docgen`, which meson looks up via pkg-config for the **BUILD machine**.
In the pseudo-cross setup, BUILD-machine `pkg-config` (the unprefixed binary) is not found by
meson — only `x86_64-unknown-linux-gnu-pkg-config` (the cross-prefixed HOST pkg-config) is
in PATH. The two cross-files provided to meson are:
- nixpkgs cross-file: specifies host binaries (cross-prefixed)
- mesonEmulatorHook cross-file: only adds `exe_wrapper = qemu-x86_64`

Neither specifies `native_file` binaries for BUILD-machine pkg-config.

## Additional Fix

`postPatch` uses `patchShebangs` without `--build` on `build-aux/qmi-codegen/qmi-codegen`
(a Python script run at build time). Changed to `--build` to use BUILD-platform python3.

`doCheck = true` would attempt to run HOST-platform test binaries; disabled for cross builds.

## Fix

In `pkgs/by-name/li/libqmi/package.nix`:

```nix
mesonFlags = [
  "-Dudevdir=${placeholder "out"}/lib/udev"
  # gtk_doc requires gi-docgen via BUILD-machine pkg-config, unavailable in pseudo-cross.
  (lib.mesonBool "gtk_doc" (withIntrospection && stdenv.buildPlatform.canExecute stdenv.hostPlatform))
  (lib.mesonBool "introspection" withIntrospection)
  (lib.mesonBool "man" withMan)
  (lib.mesonBool "qrtr" withIntrospection)
  (lib.mesonBool "udev" withIntrospection)
];

doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

postPatch = ''
  patchShebangs --build \
    build-aux/qmi-codegen/qmi-codegen
'';
```

## Note on Upstream Pattern

Other packages with `gtk_doc` enabled via introspection (libmbim, NetworkManager, etc.) may have the
same issue in pseudo-cross builds. The pattern `(lib.mesonBool "gtk_doc" (withIntrospection && stdenv.buildPlatform.canExecute stdenv.hostPlatform))` is the generic fix.
