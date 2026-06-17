# `emacs-pgtk-30.2`: libgccjit configure test fails in cross build

**Package:** `emacs-pgtk-x86_64-unknown-linux-gnu-30.2`
**File:** `pkgs/applications/editors/emacs/make-emacs.nix`
**Also:** `modules/home/r0k0r/editors/emacs/env.nix` (call site override)

## Symptom

```
configure: error: The installed libgccjit failed to compile and run a test
program using the libgccjit library; see config.log for the details of the
failure.
```

Also seen as evaluation warning:
```
Package 'emacs-pgtk-30.2' has the following problem: broken: This package is broken.
```

## Root Cause

### 1 — `broken` guard fires in pseudo-cross

`make-emacs.nix:501`:
```nix
broken = withNativeCompilation && !(stdenv.buildPlatform.canExecute stdenv.hostPlatform);
```

`canExecute` returns **false** for pseudo-cross (`buildPlatform=x86_64-linux`,
`hostPlatform=x86_64-unknown-linux-gnu`) because the platform tuples differ even
though the ISA is identical. So `broken = true` fires whenever `withNativeCompilation`
is set (the call site in `env.nix` hardcodes `withNativeCompilation = true`).

### 2 — configure hard-errors on the libgccjit runtime test

In emacs `configure` at lines 26549 and 26753:
```sh
# Check if libgccjit really works.
if test "$cross_compiling" = yes
then :
  as_fn_error "cannot run test program while cross compiling" ...
else
  # actual AC_TRY_RUN test
fi
```

Autoconf sets `cross_compiling=yes` whenever `--host` != `--build`. In pseudo-cross
both flags differ, so the test hard-errors without attempting to run. In true cross
(different ISA) this would be correct; in pseudo-cross it's overly conservative since
host binaries are executable on the build machine.

## Fix

### `make-emacs.nix`

**`broken` guard** — add same-system escape so pseudo-cross is not broken:
```nix
broken = withNativeCompilation
  && !(stdenv.buildPlatform.canExecute stdenv.hostPlatform)
  && (stdenv.buildPlatform.system != stdenv.hostPlatform.system);
```

**`preConfigure`** — patch both configure occurrences of the cross-compiling guard
to `if false` so the actual JIT runtime test runs (and succeeds, since the build
machine IS the same ISA and cc1 paths are absolute nix store paths):
```nix
preConfigure = lib.optionalString (withNativeCompilation
  && stdenv.buildPlatform != stdenv.hostPlatform
  && stdenv.buildPlatform.system == stdenv.hostPlatform.system) ''
  sed -i '/# Check if libgccjit really works\./{n; s/if test "\$cross_compiling" = yes/if false/}' configure
'';
```

The condition `buildPlatform.system == hostPlatform.system` limits this to pseudo-cross
only. True cross (different ISA) continues to error as before.

**Status: FIXED**
