# `kitty-0.46.2`: BUILD python3 RPATH leaks into cross output

**Package:** `kitty-0.46.2-x86_64-unknown-linux-gnu`
**File:** `pkgs/by-name/ki/kitty/package.nix`

## Symptom

```
error: output '.../kitty-0.46.2-x86_64-unknown-linux-gnu' is not allowed to refer
       to the following paths:
  /nix/store/37x45g0dg7z7kqgsl3vmxx5pcsblyi9p-python3-3.13.12
```

## Root Cause

`mk-python-derivation.nix` sets for all cross `buildPythonApplication` derivations:

```nix
disallowedReferences = optionals (python.stdenv.hostPlatform != python.stdenv.buildPlatform) [
  python.pythonOnBuildForHost
];
```

kitty's `buildPhase` runs setup.py with `python.pythonOnBuildForHost.interpreter`
(the BUILD machine python3). setup.py uses the running interpreter's `sysconfig` to
locate Python headers and libraries for compiling kitty's embedded-Python C code.
The resulting `linux-package/bin/kitty` binary has an RPATH containing the BUILD
python3 store path — which is exactly the path in `disallowedReferences`.

## Fix

In pseudo-cross (same ISA, `buildPlatform.system == hostPlatform.system`), the
TARGET python binary is executable on the build machine. Using TARGET python to
drive setup.py makes the C compilation use TARGET python's sysconfig, so kitty
links against TARGET libpython and the RPATH contains the TARGET python store path
(which is not in `disallowedReferences`).

```nix
pythonForSetup = if stdenv.buildPlatform.system == stdenv.hostPlatform.system
                 then python                      # TARGET python (same ISA, runnable)
                 else python.pythonOnBuildForHost; # BUILD python (true cross fallback)
```

Replace all `python.pythonOnBuildForHost.interpreter` in the Linux `buildPhase`
with `pythonForSetup.interpreter`.

Darwin `buildPhase` is unchanged (no cross Darwin builds in this context).

Applied in `pkgs/by-name/ki/kitty/package.nix`.
