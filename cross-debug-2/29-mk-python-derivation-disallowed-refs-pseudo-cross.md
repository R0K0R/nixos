# 29 — mk-python-derivation: disallowedReferences rejects BUILD python in pseudo-cross

**Package:** `kitty-0.47.4-x86_64-unknown-linux-gnu` (and all `buildPythonApplication` in pseudo-cross)  
**Fix:** `pkgs/development/interpreters/python/mk-python-derivation.nix`  
**Commit:** `e87d8fb67`

## Symptom

```
error: output '.../kitty-0.47.4-x86_64-unknown-linux-gnu' is not allowed
       to refer to the following paths:
  /nix/store/a3ivhs1k4rhnsxybkr7kwzn9kbgglw4s-python3-3.13.13
```

## Root Cause

`mk-python-derivation.nix` sets for all cross `buildPythonApplication`
derivations:

```nix
disallowedReferences = optionals (python.stdenv.hostPlatform != python.stdenv.buildPlatform) [
  python.pythonOnBuildForHost
];
```

In pseudo-cross `hostPlatform` ≠ `buildPlatform` (different `gcc.arch`),
so `disallowedReferences` is set, disallowing the BUILD python store path.

Kitty's `buildPhase` runs `setup.py` with `python.pythonOnBuildForHost.interpreter`
(the BUILD python, needed to run on the BUILD machine at build time).
`setup.py` uses the running interpreter's `sysconfig` to locate Python C
headers, so the compiled `kitty` binary gets an RPATH containing the BUILD
python store path — tripping `disallowedReferences`.

In pseudo-cross (same ISA), both python binaries execute on the same machine
and have the same ABI, so the BUILD python path in HOST output is harmless.

## Fix

Add `!(python.stdenv.isPseudoCross or false)` guard:

```nix
disallowedReferences = optionals (
  python.stdenv.hostPlatform != python.stdenv.buildPlatform
  && !(python.stdenv.isPseudoCross or false)
) [
  python.pythonOnBuildForHost
];
```

This is plan item **F13** from the fundamental-fix plan (v3 scope).

## Affected packages

Any `buildPythonApplication` whose `buildPhase` invokes `pythonOnBuildForHost`
to compile C extensions. kitty is the first observed instance; others may
surface as the pseudo-cross build progresses.

## Pattern

Cross-debug/33 (`disallowedReferences` false positive in pseudo-cross for
python derivations). The samba-specific fix (cross-debug-2/28) handles the
same root cause for packages with their own `disallowedReferences`.
