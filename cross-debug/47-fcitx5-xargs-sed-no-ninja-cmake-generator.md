# 47 — fcitx5 postConfigure: `xargs sed` "no input files" because cmake uses Makefiles, not Ninja

## Symptom

```
cmake: enabled parallel building
cmake: enabled parallel installing
sed: no input files
```

Build fails with exit code 123.  No ninja step runs; the log is only ~262 lines.

## Root Cause (two interacting bugs)

### Bug 1: GNU `xargs` runs the command once even with empty stdin

`postConfigure` (doc 41) runs:
```bash
find . -name '*.ninja' | xargs sed -i \
  's| -isystem …/glibc-dev/include||g'
```

POSIX says `xargs` should not invoke the command if there is no input.  GNU `xargs`
does the opposite: by default it **runs the command once with no arguments** when stdin
is empty.  So when `find` produces no output, `xargs` runs `sed -i 's…'` with no file
arguments, and sed prints "sed: no input files" and exits 1.  `xargs` then exits 123
(its own exit code when the invoked command exits 1–125), which kills the build.

The fix is `xargs -r` (`--no-run-if-empty`), which gives POSIX behaviour.

### Bug 2: cmake uses Makefiles — there are no `.ninja` files to find

The nixpkgs cmake setup-hook only passes `-GNinja` to cmake when `buildPhase` is set
to `ninjaBuildPhase`, which happens only when the `ninja` package is in
`nativeBuildInputs` (the ninja setup-hook sets `buildPhase=ninjaBuildPhase`).

fcitx5's `nativeBuildInputs` contained cmake and ECM, but **not `ninja`**.  So cmake
chose its default generator for Linux: **Unix Makefiles**.  The generated build
directory contains `Makefile`, `CMakeFiles/`, etc. — no `*.ninja` files.

`find . -name '*.ninja'` returns nothing → GNU xargs still runs sed → "no input files".

## Evidence

From the fcitx5 build log on yulee:
```
-- Build files have been written to: /build/source/build
cmake: enabled parallel building
cmake: enabled parallel installing
sed: no input files
```

The cmake setup-hook prints "cmake: enabled parallel building/installing" as part of
`cmakeConfigurePhase` (lines 110–118 of setup-hook.sh) BEFORE `runHook postConfigure`
(line 121).  So the sed error happens during configurePhase, not buildPhase.

## Fix

In `pkgs/by-name/fc/fcitx5/package.nix`:

1. Add `ninja` to `nativeBuildInputs` so cmake uses the Ninja generator and `.ninja`
   files actually exist when `postConfigure` runs:

```nix
nativeBuildInputs = [
  cmake
  ninja          # ← added
  kdePackages.extra-cmake-modules
  ...
];
```

2. Add `-r` to `xargs` as belt-and-suspenders (defensive against other generators or
   future regressions):

```nix
postConfigure = lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
  find . -name '*.ninja' | xargs -r sed -i \
    's| -isystem ${stdenv.cc.libc.dev}/include||g'
'';
```

## cmake Generator Decision Logic (nixpkgs)

The nixpkgs cmake setup-hook (`pkgs/build-support/cmake/setup-hook.sh`):

```bash
if [ "${buildPhase-}" = ninjaBuildPhase ]; then
    prependToVar cmakeFlags "-GNinja"
fi
```

And the ninja setup-hook sets:
```bash
buildPhase=ninjaBuildPhase
```

So the chain is: **ninja in nativeBuildInputs → ninja setup-hook fires → buildPhase=ninjaBuildPhase → cmake hook adds -GNinja → .ninja files generated**.

Any cmake package that patches `.ninja` files in `postConfigure` MUST have `ninja` in
`nativeBuildInputs`, or the patch silently does nothing (or kills the build as above).

## See also

- [[41-fcitx5-cmake-isystem-stdlib]] — the isystem issue that postConfigure is fixing
- [[32-qtbase-stdlib-h-cross-isystem]] — same root cause, qtbase variant
