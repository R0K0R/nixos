# 12 — libfprint + fprintd: three cross-build failures

## libfprint failure A: tests import HOST gi.repository at configure time

### Symptom
```
meson.build:XX: error: Python module 'gi.repository.FPrint' not found
```
during meson configure (not at test time).

### Root cause
`meson.build` runs `run_command(unittest_inspector.py, virtual-image.py)` to
discover test cases. `virtual-image.py` imports `gi.repository.FPrint`, which
requires the built libfprint shared library. In cross builds this is a HOST
library that can't be loaded by BUILD python.

### Fix
Added a cross guard around the tests subdir in `package.nix`:
```nix
mesonFlags = lib.optionals (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) [
  "--skip-subprojects=tests"
];
```
(commit `7050175a1`)

---

## libfprint failure B: examples reference `installed_tests` from skipped tests

### Symptom
```
ERROR: CMake variable 'installed_tests' referenced before assignment
```
(or meson equivalent for "Unknown variable 'installed_tests'")

### Root cause
`examples/meson.build` references `installed_tests` which is defined in
`tests/meson.build`. Since tests was skipped (fix A), the variable was never
set when examples ran.

### Fix
Also skip the examples subdir when tests is skipped:
```nix
"--skip-subprojects=tests,examples"
```
(commit `5abf119a9`)

---

## libfprint failure C: meson refuses to run HOST binaries (pseudo-cross)

### Symptom
Build tools compiled for HOST can't run during the build phase; meson
aborts with "cannot run programs during configuration".

### Root cause
Meson detects cross-compilation (different target prefix) and sets
`needs_exe_wrapper = true`, refusing to run any compiled binaries. In
pseudo-cross both BUILD and HOST are x86_64-linux, so binaries CAN run.

### Fix
Inject a meson cross file that overrides `needs_exe_wrapper`:
```nix
mesonFlags = [ "--cross-file=${pkgs.writeText "pseudo-cross.ini" ''
  [properties]
  needs_exe_wrapper = false
''}" ];
```
(commit `b712bcee7`)

---

## fprintd failure: gdbus-codegen missing at configure time

### Symptom
```
ERROR: Program 'gdbus-codegen' not found
```

### Root cause
`gdbus-codegen` is a Python script in `glib.dev/bin/` used at BUILD time to
generate D-Bus C binding code. It was in `buildInputs` (HOST libraries) not
`nativeBuildInputs`, so it was absent from PATH in cross builds.

### Fix
```nix
nativeBuildInputs = lib.optionals (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) [
  glib.dev
];
```
(commit `e488699e3`)

## Cross-debug category

- A, B: **Pattern B** (HOST binary import at BUILD configure time)
- C: **meson pseudo-cross detection** (same class as needs_exe_wrapper pattern)
- fprintd: **Pattern G3** (wrong input classification for BUILD tools)
