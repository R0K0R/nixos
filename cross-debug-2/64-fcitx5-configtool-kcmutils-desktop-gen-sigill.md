# 64 — fcitx5-configtool: KCMUtils desktop-gen SIGILL, mkKdeDerivation.kf6HostTooling not reusable

## Symptom

`fcitx5-configtool` fails on the AMD (znver5) builder:
```
make[2]: *** [src/kcm/CMakeFiles/kcm_fcitx5-kcm-desktop-gen.dir/build.make:70:
  src/kcm/CMakeFiles/kcm_fcitx5-kcm-desktop-gen] Aborted (core dumped)
```
`kcm_fcitx5-kcm-desktop-gen` is a build-time code-generation tool created by
KCMUtils' `kcmutils_add_plugin()` cmake macro. It's linked against HOST
Qt/KCMUtils (meteorlake-tuned) and then *run* as a build step to generate a
`.desktop` file — SIGILLs on the BUILD machine, same root cause as every
other Pattern-B (`*-desktop-gen`/tool-linked-against-HOST) bug in this series.

## Root Cause

`kcmutils_add_plugin()`'s cmake config checks
`CMAKE_CROSSCOMPILING AND KF6_HOST_TOOLING` and, when set, loads BUILD-platform
tool targets from `${KF6_HOST_TOOLING}/KF6KCMUtils/...` instead of building/
running the HOST-linked generator. `mk-kde-derivation.nix` already builds a
`kf6HostTooling` directory (symlinks for KF6DocTools, KF6Config, KF6Package,
KF6KCMUtils, all pointing at `pkgsBuildBuild` cmake installs) and passes
`-DKF6_HOST_TOOLING=${kf6HostTooling}` automatically — but only for packages
built via `mkKdeDerivation`.

`fcitx5-configtool` is plain `stdenv.mkDerivation` (not KDE-native), so it
never received this flag at all.

## First (incomplete) fix

Added `-DKF6_HOST_TOOLING=...` directly in `fcitx5-configtool.nix`, hand-
rolling a local host-tooling dir with **only** `KF6KCMUtils` symlinked.
Failed on the next build with two more cmake errors from packages pulled in
transitively by `kdeclarative` (→ `KF6Config`) and `libplasma`/`kpackage`
(→ `KF6Package`), which hit the *same* `KF6_HOST_TOOLING` pattern:
```
KF6PackageConfig.cmake:32: include could not find requested file: KPACKAGE_TARGETSFILE-NOTFOUND
KF6ConfigConfig.cmake:54:  include could not find requested file: KCONFIGCOMPILER_PATH-NOTFOUND
```
Root cause of *this* failure: hand-copying a subset of `kf6HostTooling`'s
symlinks from memory, rather than reusing the canonical directory, silently
drops whichever entries aren't obviously needed at a glance.

## Fundamental Fix

`kf6HostTooling` was trapped inside `mk-kde-derivation.nix`'s function
closure (the file is `self: {args}@middle: {pname,...}@args: derivation`,
and `kf6HostTooling` lives in the outer `let`, closed over by the innermost
returned lambda — not separately reachable).

Wrapped the innermost lambda's return value with `__functor` so `mkKdeDerivation`
is now an attrset (`{ __functor = ...; kf6HostTooling = ...; }`) instead of a
bare lambda: still callable exactly as before (`mkKdeDerivation { pname = ...; }`),
but now also exposes `mkKdeDerivation.kf6HostTooling` directly.

**Pitfall**: `__functor`'s first arg is conventionally named `self`, which
would have shadowed this file's actual `self:` (the KDE package-set,
used throughout for `self.sources.${pname}`, `self.${dep}`, etc.). Named it
`_mkKdeDerivation` instead.

`fcitx5-configtool.nix` now does:
```nix
kf6HostTooling = pkgsBuildBuild.kdePackages.mkKdeDerivation.kf6HostTooling;
```
— one line, always the complete/current set, no drift possible between the
canonical dir and a package's local copy.

## Files changed

- `pkgs/kde/lib/mk-kde-derivation.nix` — `__functor` wrap, export `kf6HostTooling`
- `pkgs/tools/inputmethods/fcitx5/fcitx5-configtool.nix` — `pkgsBuildBuild`
  param, `isCrossOrPseudo`-gated `-DKF6_HOST_TOOLING=...` cmakeFlag referencing
  the exported value

## See also

- cross-debug-2/07-mk-kde-derivation-qt-tools-dir-pkgsbuildBuild.md
- cross-debug-2/09-kdoctools-native-tools-waitpkg.md
- cross-debug-2/12-libfprint-fprintd-cross-failures.md — same "non-mkKdeDerivation
  package hits a KDE-only cross fix" shape; likely also fixable by referencing
  `mkKdeDerivation.kf6HostTooling` if it turns out to be the same pattern.
