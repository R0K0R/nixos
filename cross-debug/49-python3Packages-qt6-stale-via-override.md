# 49 — python3Packages.qt6 pulls stale qtquicktimeline via pyside6 → qtgraphs

## Symptom

After fixing `final.qt6` (HOST meteorlake scope) with Qt Quick native-tool patches, the
build still fails because the stale `qtquicktimeline` drv remains in the closure via:

```
toplevel → system-path → kdeconnect-kde → kcoreaddons → pyside6
  → qtgraphs → qtquicktimeline (old, unfixed drv hash)
```

`nix why-depends .#nixos... /nix/store/OLD-qtquicktimeline` confirmed this chain.

## Root Cause

`python-packages.nix:16589`:
```nix
qt6 = pkgs.qt6.override { python3 = self.python; };
```

`python3Packages.qt6` is created by calling `qt6.override`, not by reusing `final.qt6`
directly.  In our overlay (doc 48 Pitfall 2), we restore `.override` from the original:

```nix
qt6 = (prev.qt6.overrideScope qt6Fixes) // { inherit (prev.qt6) override; };
```

`prev.qt6.override` is the OLD, unfixed `makeOverridable` override function.  Calling it
returns a scope that evaluates qt6 packages WITHOUT our `qt6Fixes` applied.  So
`python3Packages.qt6.qtdeclarative` is the unfixed version, and it pulls in the old
`qtquicktimeline` drv that fails to build.

## Failed Fix: Recursive `applyQt6Fixes`

The first attempt was to replace `// { inherit (prev.qt6) override; }` with a recursive
helper that re-applies fixes whenever `.override` is called:

```nix
applyQt6Fixes = scope:
  (scope.overrideScope qt6Fixes) // {
    override = args: applyQt6Fixes (scope.override args);
  };

qt6 = applyQt6Fixes prev.qt6;
```

**Why it fails: splice.nix processes ALL scope attributes.**

nixpkgs `pkgs/top-level/splice.nix` is used by `makeScopeWithSplicing'` to construct
spliced package sets.  When `python-packages.nix` calls `pkgs.qt6.override { python3 =
self.python; }`, the result is a scope (attrset) that gets processed by `spliceReal`.

`spliceReal` constructs a `mash` by merging the scope from all platform variants:

```nix
mash =
  inputs.buildBuild
  // inputs.buildTarget
  // inputs.hostHost
  // inputs.targetTarget   -- line 31
  // inputs.buildHost
  // inputs.hostTarget;
```

Our `applyQt6Fixes` result includes `override = <custom lambda>` as a top-level
attribute of the qt6 scope attrset.  When `spliceReal` iterates with `mapAttrs merge
mash`, it encounters `override`.  The `merge` function computes:

```nix
value' = mapCrossIndex (x: x.override or { }) inputs;
-- value'.targetTarget = inputs.targetTarget.override = <our custom lambda>
```

Then for a non-derivation attrset attr, `merge` calls `spliceReal value'`.  Inside that
recursive `spliceReal`, constructing `mash' = ... // inputs.targetTarget` fails:
`inputs.targetTarget = value'.targetTarget = <our lambda>`, and `// <function>` is
illegal.

```
error: expected a set but found a function:
  «lambda override @ hosts/galaxybook4-pro360/default.nix:92:24»
```

The original `prev.qt6.override` (from `makeOverridable`) is also a lambda and is also
a member of the qt6 scope — but it does NOT trigger this error.  The difference is that
`makeScopeWithSplicing'`/`overrideScope` creates a completely fresh internal scope that
`spliceReal` evaluates atomically; `makeOverridable` then adds `override` OUTSIDE that
evaluation.  Our `// { override = <lambda>; }` attaches a lambda that, when accessed as
`inputs.X.override` by the recursive `spliceReal`, produces a function where `//` expects
a set.

## Working Fix

Override `python3Packages.qt6` directly in a separate overlay entry, pointing it at the
already-fixed `final.qt6` scope:

```nix
(final: prev:
  let
    isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
  in
  lib.optionalAttrs isMeteorLakeHost {
    python3Packages = prev.python3Packages // {
      qt6 = final.qt6;
    };
  }
)
```

`final.qt6` is the meteorlake-tuned qt6 scope with all Qt Quick fixes applied.  By
assigning it directly, `python3Packages.qt6.qtquicktimeline` is the fixed drv (same
store path as `final.qt6.qtquicktimeline`), closing the stale-drv chain.

### Why the `python3` override omission is safe

The `python3 = self.python` override in the original `pkgs.qt6.override { python3 = ...
}` controls which python3 interpreter is embedded in qt6 scope packages that have
`python3` as a function parameter (shiboken2, qt-doc codegen, etc.).  The packages in
the stale-drv chain — `qtdeclarative`, `qtgraphs`, `qtquicktimeline` — are pure C++
modules with no `python3` parameter.  They are identical under either python3.

For `pyside6` itself: it gets `python3` from its own `callPackage` invocation in
`python-packages.nix` (via `python3Packages.python`), not from the qt6 scope.

`final.qt6` uses the default `pkgs.python3` inside the scope.  Since this is the same
version as `python3Packages.python3` (same nixpkgs), there is no functional difference;
the only difference would be a distinct drv hash if the python3 package set uses a
different python3 variant, which it does not in standard nixpkgs.

### Why native (meteorlake) compilation is preserved

`final.qt6` is the HOST (meteorlake `gcc.arch`) package set — it was built with the
cross stdenv whose `hostPlatform.gcc.arch = "meteorlake"`.  All C++ Qt modules in
`final.qt6` are compiled with `-march=meteorlake` (and friends).  Assigning
`python3Packages.qt6 = final.qt6` reuses those already-built meteorlake packages; it
does not fall back to generic x86_64.

## Overlay Ordering

The `python3Packages.qt6 = final.qt6` overlay must come AFTER the `qt6` overlay that
applies `qt6Fixes`, so that `final.qt6` in the lambda is already the fixed scope.

```nix
nixpkgs.overlays = [
  ...
  # 1. Fix qt6 HOST scope (qt6Fixes applied via overrideScope)
  (final: prev: lib.optionalAttrs isMeteorLakeHost {
    qt6 = (prev.qt6.overrideScope qt6Fixes) // { inherit (prev.qt6) override; };
  })

  # 2. Point python3Packages.qt6 at the already-fixed final.qt6
  (final: prev: lib.optionalAttrs isMeteorLakeHost {
    python3Packages = prev.python3Packages // { qt6 = final.qt6; };
  })
  ...
];
```

## See also

- [[48-qt6-scope-overlay-pitfalls]] — overrideScope drops .override; isMeteorLakeHost guard
- [[46-qtdeclarative-quick-skipped-missing-qsb-tool]] — the qtdeclarative Qt Quick fix
