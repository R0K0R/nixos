# shiboken6: postInstall egg_info fails — qtpaths not in PATH in cross build

**Commit:** `8b8066f09`
**File:** `pkgs/development/python-modules/shiboken6/default.nix`

## Symptom

cmake build succeeds. `postInstall` fails:

```
RuntimeError:
setup.py invocation failed with exit code: 255.

setup.py invocation was: .../python3-x86_64-unknown-linux-gnu-3.13.13/bin/python3
  setup.py egg_info --build-type=shiboken6 --internal-build-type=shiboken6
```

Exit code 255 = Python `sys.exit(-1)`.

## Root Cause

`postInstall` runs:
```bash
python3 setup.py egg_info --build-type=shiboken6
```

The outer invocation runs `run_setup()` in `build_scripts/setup_runner.py`, which
adds an inner invocation with `--internal-build-type=shiboken6` appended. The inner
invocation calls `run_setuptools_setup()` → `setup(**kwargs)` → setuptools processes
the `egg_info` command → pyside6's `DistutilsMixIn.finalize_options()` →
`_do_finalize()` → `_determine_defaults_and_check()`.

In `options.py:_determine_defaults_and_check()`:

```python
if (not self.is_cross_compile
    and not self.qt_target_path
    and 'build_base_docs' not in sys.argv):
    if not self.qtpaths and not self.qmake and not self.qt_target_path:
        log.error("No value provided to --qtpaths option.")
        return False  # → sys.exit(-1) → exit 255
```

`qtpaths` is not in PATH in a cross build because it comes from `buildInputs`
(HOST packages), which are not added to PATH. The check always fires when
neither `--qtpaths`, `--qmake`, nor `--qt-target-path` is provided.

The `egg_info` command doesn't actually use Qt — it only generates PKG-INFO
metadata. But pyside6's setup.py always validates Qt presence regardless of
the command being run.

## Fix

Add `python.pkgs.qt6.qtbase` to `nativeBuildInputs` for cross/pseudo-cross
builds. `qtpaths6` lives in `qtbase/bin/`; putting qtbase in nativeBuildInputs
makes it findable in PATH during postInstall.

```nix
nativeBuildInputs = [
    cmake
    python.pkgs.ninja
    (python.pythonOnBuildForHost.withPackages (ps: [ ps.packaging ps.setuptools ]))
  ]
  ++ lib.optionals (stdenv.isPseudoCross or (!stdenv.buildPlatform.canExecute stdenv.hostPlatform)) [
    python.pkgs.qt6.qtbase
  ];
```

### Why not `--qt-target-path`?

An earlier attempt passed `--qt-target-path ${python.pkgs.qt6.qtbase}` to the
`egg_info` invocation. This bypasses the qtpaths check in the outer
`_determine_defaults_and_check()`. But `option_value()` (with `remove=True`)
does NOT remove `--qt-target-path` from `sys.argv` because it is not listed in
the `BootstrappingMixin.resolve()` dict. The option stays in `sys.argv` when
`setup(**kwargs)` runs the inner `egg_info` command. The standard setuptools
`EggInfo` class doesn't inherit `CommandMixin` and thus doesn't recognize
`--qt-target-path` → `error: option --qt-target-path not recognized`.
