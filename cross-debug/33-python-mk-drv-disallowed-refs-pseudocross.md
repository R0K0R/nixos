# Python mk-python-derivation: `disallowedReferences` always fails in pseudo-cross

**Package:** `kitty-x86_64-unknown-linux-gnu-0.46.2`
**File:** `pkgs/development/interpreters/python/mk-python-derivation.nix`

## Symptom

```
error: output '/nix/store/...-kitty-0.46.2-x86_64-unknown-linux-gnu' is not allowed
to refer to the following paths:
  /nix/store/37x45g0dg7z7kqgsl3vmxx5pcsblyi9p-python3-3.13.12
```

The forbidden path is `python.pythonOnBuildForHost` (the BUILD python).

## Root Cause

`mk-python-derivation.nix` line ~404:
```nix
disallowedReferences = optionals (python.stdenv.hostPlatform != python.stdenv.buildPlatform) [
  python.pythonOnBuildForHost
];
```

In pseudo-cross (buildPlatform=x86_64-linux, hostPlatform=x86_64-unknown-linux-gnu):
- `python` (TARGET/HOST python for x86_64-unknown-linux-gnu) and
- `python.pythonOnBuildForHost` (BUILD python for x86_64-linux)

are **the same derivation** (same store hash). Nixpkgs reuses native packages
when `buildPlatform.system == hostPlatform.system` (both = "x86_64-linux").

So any Python package built with the cross compiler will ALWAYS reference
`python.pythonOnBuildForHost` (since it IS `python`), and this check can never pass.

## Attempted (Wrong) Fix

Kitty's `buildPhase` was changed to use `pythonForSetup = python` (TARGET python)
when `buildPlatform.system == hostPlatform.system`. But since TARGET python ==
BUILD python in pseudo-cross, the store path in the output is the same, and the
`disallowedReferences` check still fires.

## Correct Fix

Skip the `disallowedReferences` check in pseudo-cross (same `system` string, different
platform tuples). Using BUILD python in pseudo-cross output is safe because the
host and build machines have the same ISA and the python binary works on both.

In `mk-python-derivation.nix`:
```nix
disallowedReferences = optionals (
  python.stdenv.hostPlatform != python.stdenv.buildPlatform
  && python.stdenv.hostPlatform.system != python.stdenv.buildPlatform.system
) [
  python.pythonOnBuildForHost
];
```

The `&& system != system` condition excludes pseudo-cross while keeping the check
for true cross builds (different ISA).

**Status: FIXED**
