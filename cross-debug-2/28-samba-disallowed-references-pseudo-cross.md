# 28 — samba: disallowedReferences rejects BUILD python in pseudo-cross

**Package:** `samba-x86_64-unknown-linux-gnu-4.23.8`  
**Fix:** `pkgs/servers/samba/4.x.nix`  
**Commit:** `572e99f13`

## Symptom

```
error: output '.../samba-x86_64-unknown-linux-gnu-4.23.8' is not allowed
       to refer to the following paths:
  /nix/store/a3ivhs1k4rhnsxybkr7kwzn9kbgglw4s-python3-3.13.13
```

## Root Cause

`samba/4.x.nix` sets:

```nix
isCross = !lib.systems.equals stdenv.hostPlatform stdenv.buildPlatform;

disallowedReferences = lib.optionals isCross [
  buildPackages.python3Packages.python  # BUILD python
  buildPackages.runtimeShellPackage
];
```

In pseudo-cross, `isCross = true` because `hostPlatform` (meteorlake) ≠
`buildPlatform` (znver5) — `lib.systems.equals` compares the full platform
spec including `gcc.arch`. So the BUILD python path becomes disallowed.

Samba uses Python (waf build system, Python bindings) and the BUILD python
interpreter ends up referenced in the installed scripts via `wrapPythonPrograms`.
In a real cross build (aarch64 HOST), embedding the x86_64 BUILD python path
would be wrong. In pseudo-cross (both x86_64), it's harmless.

## Fix

Add `&& !stdenv.isPseudoCross` guard:

```nix
disallowedReferences = lib.optionals (isCross && !stdenv.isPseudoCross) [
  buildPackages.python3Packages.python
  buildPackages.runtimeShellPackage
];
```

## Pattern

Cross-debug/33 (python `disallowedReferences` false positive in pseudo-cross).
Samba has its own explicit `disallowedReferences`; the general case is handled
by the `mk-python-derivation` fix (cross-debug-2/29).
