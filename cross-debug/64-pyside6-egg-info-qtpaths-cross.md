# cross-debug/64: pyside6 postInstall egg_info exits 255 in cross builds

## Problem

pyside6 cmake build succeeds, but postInstall fails:

```
RuntimeError:
setup.py invocation failed with exit code: 255.

setup.py invocation was: /nix/store/.../python3.13 setup.py egg_info \
  --build-type=pyside6 --internal-build-type=pyside6
```

Exit code 255 = `sys.exit(-1)` in Python.

## Root cause

`postInstall` runs:
```bash
${python.pythonOnBuildForHost.interpreter} setup.py egg_info --build-type=pyside6
```

This outer invocation spawns an inner subprocess with `--internal-build-type=pyside6`.

In the inner subprocess, `build_scripts/options.py:find_qtpaths()` runs:
1. Line 109: `if self.dict["internal-build-type"] is None: return None` — skipped
   (outer call returns None here, only inner call reaches the rest)
2. `qtpaths = which("qtpaths6")` — returns None (HOST qttools not in PATH in cross build)
3. `qtpaths = which("qtpaths")` — returns None
4. `sys.exit(-1)` — exits with code 255

**Why qtpaths6 is missing in cross builds:**
In native nixpkgs builds, `buildInputs` bin directories ARE in PATH (buildPlatform == hostPlatform).
`python.pkgs.qt6.qttools` (in `buildInputs`) provides `bin/qtpaths6` in PATH.
In cross builds, `buildInputs` are HOST platform packages — their bin dirs are NOT in PATH
(they'd SIGILL on the AMD builder anyway if executed).

## Fix

Add `pkgsBuildBuild` to `pyside6/default.nix` and pass `--qtpaths` explicitly in cross builds,
pointing to BUILD-platform qttools' `qtpaths6` (which can run on the AMD builder):

```nix
{
  pkgsBuildBuild,
  ...
}:
stdenv.mkDerivation (finalAttrs: {
  ...
  postInstall = ''
    cd ../../..
    chmod +w .
    ${python.pythonOnBuildForHost.interpreter} setup.py egg_info --build-type=pyside6 \
      ${lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform)
        "--qtpaths=${pkgsBuildBuild.qt6.qtbase}/bin/qtpaths6"}
    cp -r PySide6.egg-info $out/${python.sitePackages}/
    ...
  '';
```

`pkgsBuildBuild.qt6.qtbase/bin/qtpaths6` is the BUILD-platform (generic x86_64) qtpaths6,
which can be executed on the AMD builder. NOTE: `qtpaths6` is in qtbase, not qttools.
`available_pyside_tools` then looks for pyside6 libexec tools in
`pkgsBuildBuild.qt6.qtbase/libexec/` (uic, rcc present; qml tools are in qtdeclarative),
so the egg_info entry_points are populated for the core tools.

## Why exit code is 255, not signal code

`sys.exit(-1)` in Python → process exits with code `(-1) % 256 = 255`.
Not a signal death (which would give negative return code in Python subprocess).
The inner subprocess outputs nothing because `sys.exit(-1)` is called before any output.

## Files

- `pkgs/development/python-modules/pyside6/default.nix`
