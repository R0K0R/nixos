# blender: preConfigure calls bare `python`, not in PATH in nix sandbox

**Commit:** `6203ea501`
**File:** `pkgs/by-name/bl/blender/package.nix`

See also: `cross-debug/93-blender-preConfigure-bare-python.md`

## Symptom

```
/nix/store/.../setup: line 271: python: command not found
```

Fails immediately at configurePhase before cmake runs.

## Root Cause

`preConfigure` checks the Python version at build time:

```bash
actual_python_version=$(python -c 'import sys; print(".".join(map(str, sys.version_info[0:2])))')
```

`python` (Python 2 bare name) is not in the nix sandbox PATH. `python3Packages.wrapPython`
in `nativeBuildInputs` provides `wrapPythonPrograms` (a shell function), not a
`python3` binary.

## Fix

Replace the runtime invocation with a Nix-time string interpolation — `python3` is
already bound in the `let` block as `python313Packages.python`:

```nix
actual_python_version="${python3.pythonVersion}"
```

No binary needed at build time; the version string is baked in at eval time.
