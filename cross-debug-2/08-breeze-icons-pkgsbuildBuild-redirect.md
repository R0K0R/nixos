# breeze-icons: compile-and-run helper targets HOST arch, crash on AMD builder

**Commit:** `7ea458427`
**File:** `pkgs/kde/frameworks/breeze-icons/default.nix`

See also: `cross-debug/44-breeze-icons-qrcalias-host-binary-runs-on-builder.md`

## Symptom

```
Incompatible processor. This Qt build requires the following features: waitpkg
```

Build crashes in cmake phase on yulee (AMD Ryzen, no waitpkg).

## Root Cause

breeze-icons compiles two cmake helper tools (`qrcAlias`, `generate-symbolic-dark`)
using the HOST compiler (meteorlake-tuned gcc) during its own cmake build phase,
then immediately executes them on the build machine. The HOST binaries contain
meteorlake-specific instructions (waitpkg) and crash on AMD.

The output (SVG icon theme + `.rcc` files) is pure data — fully architecture-independent.

## Fix

Redirect the cross/pseudo-cross derivation to the BUILD-platform breeze-icons:

```nix
if (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform
then pkgsBuildBuild.kdePackages.breeze-icons
else mkKdeDerivation {
  pname = "breeze-icons";
  ...
}
```

`pkgsBuildBuild.kdePackages.breeze-icons` evaluates with `buildPlatform == hostPlatform`
and takes the `mkKdeDerivation` branch (no cross condition fires). No circular
evaluation. The data output is identical regardless of which platform built it.
