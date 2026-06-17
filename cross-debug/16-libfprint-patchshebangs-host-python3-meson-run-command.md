# `libfprint`: Meson `run_command()` Fails with HOST Python3 Shebang in Cross Build

**Package:** `libfprint-x86_64-unknown-linux-gnu-1.94.10`
**File:** `pkgs/by-name/li/libfprint/package.nix`

## Symptom

```
tests/meson.build:106:16: ERROR: Could not execute command `/build/source/tests/unittest_inspector.py /build/source/tests/virtual-image.py`.
```

## Root Cause

Three interacting factors:

1. **`postPatch` calls `patchShebangs` (without `--build`)** on test scripts including
   `tests/unittest_inspector.py`. Without `--build`, `patchShebangs` patches shebangs with
   the HOST-platform interpreter — in a pseudo-cross build, that's a cross-compiled
   `python3` binary that cannot execute on the BUILD machine.

2. **`tests/meson.build:96` calls `find_program('unittest_inspector.py')`** and then
   **line 106 calls `run_command(unittest_inspector, ...)`** at meson configure time.
   Meson `run_command()` runs at configure time, not at build time.

3. **The virtual driver test block is gated by `if get_option('introspection')`** (line 88),
   and `gobject-introspection` is in `nativeBuildInputs`, so introspection IS enabled.
   Meson therefore enters the block and tries to execute `unittest_inspector.py`.

## Why `patchShebangs --build` Works

The BUILD-platform `python3` is available during `postPatch` via `gobject-introspection`
(which is in `nativeBuildInputs` and depends on python3). With `--build`, the shebang
is patched to the BUILD-platform python3 path, so the script can run at meson configure
time on the build machine.

## Why `doInstallCheck` Must Be Disabled for Cross Builds

The install check runs `ninjaCheckPhase` which executes compiled test binaries (HOST-platform
fingerprint driver tests). These cannot run on the BUILD machine in a cross build.

## Fix

In `pkgs/by-name/li/libfprint/package.nix`:

```nix
postPatch = ''
  patchShebangs --build \
    tests/test-runner.sh \
    tests/unittest_inspector.py \
    tests/virtual-image.py \
    tests/umockdev-test.py \
    tests/test-generated-hwdb.sh
'';

# ...

doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```

Key points:
- `patchShebangs --build` is safe for non-cross builds too (build == host, same result)
- `gobject-introspection` in `nativeBuildInputs` ensures BUILD python3 is in PATH during `postPatch`
- `stdenv.buildPlatform.canExecute stdenv.hostPlatform` is false in pseudo-cross builds
