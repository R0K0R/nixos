# `libfprint`: Three-Stage Cross-Build Failure

**Package:** `libfprint-x86_64-unknown-linux-gnu-1.94.10`
**File:** `pkgs/by-name/li/libfprint/package.nix`

---

## Stage 1: Meson configure-time `run_command()` fails

### Symptom
```
tests/meson.build:106:16: ERROR: Could not execute command `/build/source/tests/unittest_inspector.py /build/source/tests/virtual-image.py`.
```

### Root Cause
`postPatch` called `patchShebangs` (without `--build`) on test scripts.
- Without `--build`, patchShebangs patches shebangs with HOST-platform interpreters
- But python3 was NOT in PATH during postPatch (only in `nativeInstallCheckInputs`)
- Result: shebang unchanged, still `#!/usr/bin/env python3`
- Meson's `run_command()` at configure time can't exec the script: `/usr/bin/env` doesn't exist in the Nix sandbox

The configure-time execution happens inside `if get_option('introspection')` in `tests/meson.build:88`, gated by `gobject-introspection` being found.

### Fix
1. Add `python3` to `nativeBuildInputs` (enables `patchShebangs --build` to find it)
2. Change `patchShebangs` to `patchShebangs --build` in `postPatch`

---

## Stage 2: `fprint-list-udev-hwdb` needs exe_wrapper during build

### Symptom
```
ERROR: An exe_wrapper is needed for /build/source/build/libfprint/fprint-list-udev-hwdb but was not found. Please define one in cross file and check the command and/or add it to PATH.
```

### Root Cause
After fixing Stage 1, configure succeeds but the build phase tries to run
`fprint-list-udev-hwdb` (a compiled HOST-platform binary) to generate udev hwdb entries.
Without `mesonEmulatorHook`, no `exe_wrapper` is defined in the meson cross-file, so meson
refuses to run the binary.

### Fix
Add `mesonEmulatorHook` to `nativeBuildInputs` for cross builds:
```nix
++ lib.optionals (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) [
  mesonEmulatorHook
];
```

---

## Stage 3: Install checks would fail (pre-empted)

### Root Cause
`doInstallCheck = true` would run `ninjaCheckPhase` which executes HOST-platform
fingerprint driver tests and compiled binaries — cannot run on the BUILD machine.

### Fix
```nix
doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```

---

## Full Fix Applied to `pkgs/by-name/li/libfprint/package.nix`

```nix
# Added to function args:
mesonEmulatorHook,

# postPatch:
postPatch = ''
  patchShebangs --build \
    tests/test-runner.sh \
    tests/unittest_inspector.py \
    tests/virtual-image.py \
    tests/umockdev-test.py \
    tests/test-generated-hwdb.sh
'';

# nativeBuildInputs appended:
python3   # so patchShebangs --build can find it at postPatch time
]
++ lib.optionals (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) [
  mesonEmulatorHook  # exe_wrapper for HOST-platform binaries run at build time
];

# Changed:
doInstallCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```
