# cross-debug/93: blender — preConfigure calls bare `python` (not found in sandbox)

**Package:** `blender-x86_64-unknown-linux-gnu-5.1.1.drv`
**File:** `pkgs/by-name/bl/blender/package.nix`, `preConfigure`

## Symptom

```
Running phase: configurePhase
/nix/store/.../stdenv-linux/setup: line 271: python: command not found
```

Build fails immediately at configurePhase before cmake even runs.

## Root Cause

`blender/package.nix` has a `preConfigure` hook that checks the Python version matches
what blender expects:

```bash
preConfigure = ''
  (
    expected_python_version=$(grep -E ... FindPythonLibsUnix.cmake | ...)
    actual_python_version=$(python -c 'import sys; ...')
    if ! [[ "$actual_python_version" = "$expected_python_version" ]]; then
      ...
    fi
  )
'';
```

The script calls `python` (Python 2 style bare name). In the nix sandbox `python` is not
provided; only `python3` is available (via `python3Packages.wrapPython` in `nativeBuildInputs`).
This is not cross-build-specific — it would fail on any modern nixpkgs build — but surfaces
here because we're building blender cross-compiled for the first time.

## Fix

Replace the runtime `python`/`python3` invocation with a Nix-time string interpolation.
`python3.pythonVersion` is a Nix attribute (e.g. `"3.13"`) evaluated when the derivation is
built — no interpreter binary needed at build time:

```nix
# Before (calls python at build time — not in PATH in cross sandbox):
actual_python_version=$(python -c 'import sys; print(".".join(map(str, sys.version_info[0:2])))')

# After (Nix-time interpolation — no runtime python needed):
actual_python_version="${python3.pythonVersion}"
```

Note: `python3 -c ...` was also tried as an intermediate step, but `python3Packages.wrapPython`
(in `nativeBuildInputs`) provides only a shell function (`wrapPythonPrograms`), not a `python3`
binary in PATH. Adding the HOST platform `python3` to `nativeBuildInputs` would be wrong
(cross-compiled, can't run on build machine). The Nix-time interpolation avoids the issue entirely.

Applied in `pkgs/by-name/bl/blender/package.nix` `preConfigure`.
