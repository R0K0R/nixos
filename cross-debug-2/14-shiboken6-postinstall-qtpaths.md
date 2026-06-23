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

## Attempted Fix 1 (broken): `--qt-target-path`

Passing `--qt-target-path ${python.pkgs.qt6.qtbase}` to the `egg_info`
invocation bypasses the qtpaths check. But `option_value()` (with `remove=True`)
does NOT remove `--qt-target-path` from `sys.argv` because it is not in
`BootstrappingMixin.resolve()`. The option stays in `sys.argv` when
`setup(**kwargs)` runs the inner `egg_info` command. The standard setuptools
`EggInfo` class doesn't inherit `CommandMixin` so doesn't recognize the option
→ `error: option --qt-target-path not recognized`.

## Attempted Fix 2 (broken): qtbase in nativeBuildInputs

Adding `python.pkgs.qt6.qtbase` to nativeBuildInputs makes `qtpaths6` findable,
which fixes the qtpaths check. But then `_do_finalize()` proceeds to call
`QtInfo().setup()` → `_get_other_properties()` → `_get_cmake_mkspecs_variables()`
which runs a cmake config test:

```
cmake -DCMAKE_PREFIX_PATH=/nix/store/.../qtbase-x86_64-unknown-linux-gnu-6.11.0
```

The HOST qtbase's `Qt6CoreConfig.cmake` requires `Qt6CoreTools` (moc, rcc, etc.)
which only exists in the BUILD-platform `qtbase-6.11.0`. HOST qtbase doesn't ship
it. cmake fails: `Could NOT find Qt6CoreTools (missing: Qt6CoreTools_DIR)`.

## Actual Fix (commit `4c1ec83a7`)

Skip `setup.py egg_info` entirely for cross/pseudo-cross builds and write the
egg-info directory manually. The egg-info is only package metadata; the cmake
probe inside `qtinfo._get_cmake_mkspecs_variables()` is not needed for it.

```nix
postInstall =
  if (stdenv.isPseudoCross or (!stdenv.buildPlatform.canExecute stdenv.hostPlatform)) then ''
    eggdir=$out/${python.sitePackages}/shiboken6.egg-info
    mkdir -p "$eggdir"
    printf 'Metadata-Version: 2.1\nName: shiboken6\nVersion: ...\n...\n' \
      > "$eggdir/PKG-INFO"
    printf 'shiboken6\n' > "$eggdir/top_level.txt"
    touch "$eggdir/dependency_links.txt"
  '' else ''
    cd ../../..
    python3 setup.py egg_info --build-type=shiboken6
    cp -r shiboken6.egg-info $out/${python.sitePackages}/
  '';
```
