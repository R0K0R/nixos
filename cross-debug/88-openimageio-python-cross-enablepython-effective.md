# 88 — openimageio: Python cross mismatch affects both top-level and python3Packages variant

## Symptom

```
CMake Error at src/cmake/dependency_utils.cmake:180 (message):
  Python3 is required, aborting.
```

Two derivations fail:
- `openimageio-x86_64-unknown-linux-gnu-3.1.13.1.drv` (from `pkgs.openimageio`)
- Another `openimageio-x86_64-unknown-linux-gnu-3.1.13.1.drv` (from `python3Packages.openimageio`)

## Root Cause

pybind11's cmake hook runs during configure and:
- Sets `PYTHON_EXECUTABLE` from the BUILD-side python (native, runs on builder)
- Sets `PYTHON_INCLUDE_DIR` / `PYTHON_SITE_PACKAGES` from the HOST-side python (cross target)

cmake's `find_package(Python3)` can't reconcile a native executable with cross-target headers —
the version/config check fails → "Python3 not found" → hard abort because openimageio treats
Python as required when `USE_PYTHON=ON`.

## Why the overlay `python3Packages // { openimageio = ... }` doesn't work

`python3Packages` in nixpkgs is a `makeScope`-based package set. Packages inside the scope
have their inter-dependencies baked in at scope-creation time. Doing:

```nix
python3Packages = prev.python3Packages // { openimageio = our-fixed-version; }
```

changes `pkgs.python3Packages.openimageio` but does NOT affect what
`pkgs.python3Packages.materialx` uses internally — materialx was already evaluated with the
original `openimageio` from the scope. The scope-internal reference is frozen.

## Why `openimageio = prev.openimageio.override { enablePython = false; }` in the overlay is
## also insufficient

`python-packages.nix` defines:
```nix
openimageio = toPythonModule (
  pkgs.openimageio.override { enablePython = true; python3Packages = self; }
);
```

This explicitly re-enables Python, undoing the overlay. The `python3Packages.openimageio`
drv gets the Python-enabled hash `p6xyq852` regardless.

## Fix (in nixpkgs-patch)

Gate Python support on being in a NATIVE build. In `pkgs/by-name/op/openimageio/package.nix`:

```nix
let
  # In cross builds (including pseudo-cross where hostPlatform.gcc.arch differs)
  # pybind11's cmake hook mixes native PYTHON_EXECUTABLE with cross PYTHON_INCLUDE_DIR.
  # cmake's find_package(Python3) can't reconcile them and aborts.
  # Gate Python support here so callers passing enablePython = true can't force a cross failure.
  enablePythonEffective = enablePython && stdenv.hostPlatform == stdenv.buildPlatform;
in
stdenv.mkDerivation (finalAttrs: {
  ...
  nativeBuildInputs = [ cmake unzip ]
    ++ lib.optional enablePythonEffective python3Packages.pybind11;

  cmakeFlags = [
    (lib.cmakeBool "USE_PYTHON" enablePythonEffective)
    ...
  ];
```

This covers:
- Top-level `pkgs.openimageio` → `enablePythonEffective = false` in cross builds
- `python3Packages.openimageio` (which calls `.override { enablePython = true; }`) → still
  `enablePythonEffective = false` in cross builds — the gate overrides the caller's request

## Dependency chain that surfaced this

`python3Packages.openimageio` → `python3Packages.materialx` → `python3Packages.openusd` →
`blender`

blender uses openusd/materialx for its Python scripting layer. The Python-enabled openimageio
is needed for Python materialx bindings, which blender uses for USD support.
