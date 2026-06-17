# 41: shiboken6 embedding_generator: Python_EXECUTABLE empty in cross cmake

## Error
```
FAILED: [code=127] ...signature_bootstrap_inc.h ...
cd /build/.../libshiboken && -E /build/.../embedding_generator.py --cmake-dir ... --use-pyc FALSE
sh: line 1: -E: command not found
```
And cmake output:
```
-- Python_Interpreter_FOUND:     FALSE
-- Python_EXECUTABLE:
CMake Warning: Manually-specified variables were not used by the project:
    Python3_EXECUTABLE
```

## Root cause
The existing nixpkgs fix passes `-DPython3_EXECUTABLE=` (using the `Python3`
cmake module variable), but shiboken6's CMakeLists.txt calls
`find_package(Python ...)` (without the 3). The relevant cmake variable is
`Python_EXECUTABLE` (no 3). So the hint was going to the wrong variable.

In cmake cross-compilation mode, `find_package(Python COMPONENTS Interpreter)`
cannot find the build-machine Python (restricted to sysroot). `Python_EXECUTABLE`
ends up empty, making the embedding_generator custom command start with
`${empty} -E script.py` → `sh: -E: command not found`.

## Fix
`pkgs/development/python-modules/shiboken6/default.nix`

Add `-DPython_EXECUTABLE=${python.pythonOnBuildForHost.interpreter}` to
`cmakeFlags` alongside the existing (but ineffective) `Python3_EXECUTABLE` line.
