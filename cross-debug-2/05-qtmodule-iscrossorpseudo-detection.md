# qtModule.nix: stdenv.buildPlatform != stdenv.hostPlatform unreliable for pseudo-cross

**Commit:** `7ea458427`
**File:** `pkgs/development/libraries/qt-6/qtModule.nix`

See also: `cross-debug/31-libbpf-packed-werror-gcc15.md` iteration 2 for the
original discovery of this issue.

## Problem

`qtModule.nix` used `stdenv.buildPlatform != stdenv.hostPlatform` as the condition
for cross-build cmake flags. In pseudo-cross (same system tuple, different
`gcc.arch`), Nix attrset `!=` short-circuits on thunks and returns the same hash
regardless of whether the condition holds. The cross flags were silently skipped.

## Fix

Replace all 7 occurrences with:

```nix
isCrossOrPseudo =
  (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```

`canExecute` is a plain boolean (no thunk short-circuit). `isPseudoCross` is the
explicit flag added by F1 (`default.nix` / `make-derivation.nix`). This two-part
condition is now canonical across the tree for pseudo-cross detection.
