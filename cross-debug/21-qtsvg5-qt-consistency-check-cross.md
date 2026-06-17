# `qtsvg-5.15.18`: Qt Consistency Check Fails in Cross Build

**Package:** `qtsvg-x86_64-unknown-linux-gnu-5.15.18`
**File:** `pkgs/development/libraries/qt-5/hooks/qtbase-setup-hook.sh`

## Symptom

```
Error: detected mismatched Qt dependencies:
    /nix/store/plyfryk6rjad5z2mvzlabvjnbnd8knbb-qtbase-x86_64-unknown-linux-gnu-5.15.18-dev
    /nix/store/hrlhw4g0q4cvw6acp3402cgrxl3f9gjd-qtbase-x86_64-unknown-linux-gnu-5.15.18-dev
```

## Root Cause

`qtModule.nix` lines 39-41 explicitly add a second qtbase-dev to `nativeBuildInputs`
in cross builds:

```nix
++ lib.optionals (stdenv.buildPlatform != stdenv.hostPlatform) [
    pkgsHostTarget.qt5.qtbase.dev
];
```

This is intentional: in a cross build, the HOST-platform qtbase-dev is needed
in the build environment to provide cross-compilation mkspecs and qmake. The
`qtsvg` package also has qtbase in its `propagatedBuildInputs` (for linking).

In a pseudo-cross build (`buildPlatform != hostPlatform` even though ISA matches),
both qtbase-dev packages are for `x86_64-unknown-linux-gnu-5.15.18` but with
different Nix store hashes (different compilation flags, dependency closures).

The `qtbase-setup-hook.sh` consistency check compares store paths directly:
```bash
if [[ "$__nix_qtbase" != "@dev@" ]]; then
    echo >&2 "Error: detected mismatched Qt dependencies:"
    exit 1
fi
```

The first qtbase sets `__nix_qtbase="<path-A>"`. The second qtbase's hook fires
and sees `<path-A> != <path-B>`, triggering the error.

## Fix

Patch `qtbase-setup-hook.sh` to compare package names (strip the Nix store hash)
rather than full paths:

```bash
_qt_name_cur="${@dev@##*/}"; _qt_name_cur="${_qt_name_cur#*-}"
_qt_name_set="${__nix_qtbase##*/}"; _qt_name_set="${_qt_name_set#*-}"
if [[ "$_qt_name_cur" != "$_qt_name_set" ]]; then
    echo >&2 "Error: detected mismatched Qt dependencies:"
    exit 1
fi
```

This allows two builds of `qtbase-x86_64-unknown-linux-gnu-5.15.18-dev` (same
name, different hash) to coexist — correct for cross builds. It still catches
genuine mismatches like Qt 5.14 vs 5.15 (different version in name).

## Note

The `pkgsHostTarget.qt5.qtbase.dev` in `nativeBuildInputs` differs from the
`qtbase.dev` in the Qt5 scope because `pkgsHostTarget` is a separate instantiation
of the package set. In a pseudo-cross build both have the same platform prefix
but are evaluated through different code paths, resulting in different store hashes.
