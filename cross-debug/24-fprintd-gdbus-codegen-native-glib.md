# `fprintd-1.94.5`: `gdbus-codegen` not found in cross build

**Package:** `fprintd-x86_64-unknown-linux-gnu-1.94.5`
**File:** `pkgs/by-name/fp/fprintd/package.nix`

## Symptom

```
Did not find pkg-config by name 'pkg-config'
Found pkg-config: NO
Build-time dependency gio-2.0 found: NO (tried pkgconfig and cmake)
Program gdbus-codegen found: NO
src/meson.build:9:29: ERROR: Program 'gdbus-codegen' not found or not executable
```

## Root Cause

`gdbus-codegen` is a build-time tool from glib that runs on the build machine
to generate D-Bus boilerplate C code. In cross builds, `buildInputs = [ glib ]`
provides the HOST (cross-compiled) glib whose executables can't run on the
build machine.

`gdbus-codegen` must come from the BUILD machine's glib (i.e., glib in
`nativeBuildInputs`). It was missing entirely from `nativeBuildInputs`.

## Fix

Add `glib` to `nativeBuildInputs`:

```nix
nativeBuildInputs = [
  pkg-config
  meson
  ninja
  perl
  gettext
  gtk-doc
  python3
  libxslt
  glib  # ← added: provides gdbus-codegen for build machine
  dbus
  docbook-xsl-nons
  docbook_xml_dtd_412
];
```
