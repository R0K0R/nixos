# 48 — Pitfalls when overlaying the `qt6` scope in nixpkgs

Three non-obvious problems encountered when patching Qt modules via a nixpkgs overlay.

---

## Pitfall 1: Targeting `qt6Packages` instead of `qt6`

**Symptom:** Overlay changes Qt module behaviour (e.g. adds cmake flags to
`qtdeclarative`) but downstream builds see the old behaviour unchanged.

**Root cause:**

In nixpkgs `pkgs/top-level/all-packages.nix`:

```nix
qt6 = recurseIntoAttrs (callPackage ../development/libraries/qt-6 { });

qt6Packages = recurseIntoAttrs (
  import ./qt6-packages.nix { ... qt6 = pkgsHostTarget.qt6; ... }
);
```

`qt6` is the **real Qt6 module scope** (qtbase, qtdeclarative, qtscxml, …).
`qt6Packages` is a **separate application wrapper scope** that references
`pkgsHostTarget.qt6` internally — it does NOT own the Qt modules.

Overriding `qt6Packages` has no effect on Qt modules.  Override `qt6`:

```nix
qt6 = (prev.qt6.overrideScope (_qfinal: qprev: {
  qtdeclarative = qprev.qtdeclarative.overrideAttrs (...);
})) // { inherit (prev.qt6) override; };  # see Pitfall 2
```

---

## Pitfall 2: `overrideScope` drops the `.override` attribute

**Symptom:** Evaluation error after applying `qt6.overrideScope`:

```
error: attribute 'override' missing
at pkgs/top-level/python-packages.nix:16589:9:
  qt6 = pkgs.qt6.override { python3 = self.python; };
```

**Root cause:**

`qt6` in nixpkgs is created by `callPackage`, which wraps the scope in
`lib.makeOverridable`, adding `.override` and `.overrideDerivation`.

`prev.qt6.overrideScope(f)` returns a **new scope** from `makeScopeWithSplicing'`
that does NOT have the `makeOverridable`-added `.override`.

**Fix:** Restore `.override` from the original after `overrideScope`:

```nix
qt6 = (prev.qt6.overrideScope (_qfinal: qprev: {
  ...
})) // { inherit (prev.qt6) override; };
```

The `python3Packages.qt6` scope created by `prev.qt6.override { python3 = ...; }` won't
include our fixes to qtdeclarative/qtscxml, but that's acceptable — Python Qt bindings
don't need the Qt Quick host-build fixes.

---

## Pitfall 3: Overlay propagates to `pkgsBuildBuild`, rebuilding native packages

**Symptom:** Build runs two `qtdeclarative-6.11.0.drv` variants — one for HOST (fixed)
and a second unexpected one that breaks the native (build-platform) qtdeclarative.

**Root cause:**

nixpkgs overlays apply to ALL package sets, including `pkgsBuildBuild`.  An overlay
that modifies `qt6` will also modify `pkgsBuildBuild.qt6`.  If the fix references
`final.pkgsBuildBuild.qt6.${attr}` (to get the native tools), and that attribute is
itself a modified version, you get a self-referential rebuild.

**Fix:** Guard the overlay with an `isMeteorLakeHost` check so it only fires for the
HOST package set:

```nix
(final: prev:
  let
    isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
  in
  lib.optionalAttrs isMeteorLakeHost {
    qt6 = (prev.qt6.overrideScope (...)) // { inherit (prev.qt6) override; };
  }
)
```

In `pkgsBuildBuild`, `hostPlatform.gcc.arch` is empty (generic x86_64), so the guard
correctly skips the override there.  `final.pkgsBuildBuild.qt6.qtshadertools` then
refers to the unmodified native package — no cycle.

---

## Pitfall 4: Stale nix eval cache returns old drv hashes

**Symptom:** A build run uses old drv hashes for packages that should have been
invalidated by the overlay change.  `nix eval .#...drvPath` returns the new hash,
but the running `nix build` uses the old one.

**Root cause:**

Nix caches evaluation results in `~/.cache/nix/eval-cache-v6/*.sqlite`.  If the cache
entry for the flake was written before the overlay change, `nix build` may use the
cached (stale) derivations.

**Diagnosis:** Run `nix eval .#nixosConfigurations.HOST.pkgs.qt6.qtquicktimeline.drvPath`
after the overlay change.  If it disagrees with what `nix build --dry-run` reports,
the eval cache is stale.

**Fix:** The cache is invalidated when the flake's `narHash` changes (i.e., when the
nixpkgs or flake source changes).  For a dirty working tree, Nix re-evaluates on each
run.  The stale-cache window is typically limited to a single build session.

---

## See also

- [[45-qt-tool-packages-missing-in-pseudo-cross-cmake]] — why native Qt tool cmake dirs
  are not found and how `nativeBuildInputs` + `-DQt6XxxTools_DIR` fixes it
- [[46-qtdeclarative-quick-skipped-missing-qsb-tool]] — qtdeclarative Qt Quick fix that
  triggered all of the above pitfalls
