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

Pass `--qt-target-path` pointing to qt6.qtbase (which is already a `buildInput`
and therefore exists in the nix store). When `qt_target_path` is set,
`_determine_defaults_and_check()` skips the qtpaths requirement entirely (only
checks that the provided path exists, which it does).

```nix
# Before:
python3 setup.py egg_info --build-type=shiboken6

# After:
python3 setup.py egg_info --build-type=shiboken6 \
  --qt-target-path ${python.pkgs.qt6.qtbase}
```

The `--qt-target-path` propagates to the inner invocation automatically via
`setup_runner.new_setup_internal_invocation()` which forwards all original
argv to the subprocess.
