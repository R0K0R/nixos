# shiboken6: QFP_PYTHON_HOST_PATH empty when SHIBOKEN_IS_CROSS_BUILD=TRUE

**Commit:** `b0a23e0df`
**File:** `pkgs/development/python-modules/shiboken6/default.nix`

See also: `cross-debug/41`, `cross-debug/42`

## Symptom

```
cd /build/pyside-setup/sources/shiboken6/build/libshiboken && \
  -E /build/.../embedding_generator.py --cmake-dir ... --use-pyc FALSE
sh: line 1: -E: command not found
exit status 127
```

The `add_custom_command` for `embedding_generator.py` expands to `-E script.py`
with nothing before `-E` — as if the python interpreter variable is empty.

## Root Cause

`libshiboken/CMakeLists.txt` branches on `SHIBOKEN_IS_CROSS_BUILD`:

```cmake
if(SHIBOKEN_IS_CROSS_BUILD)
    set(host_python_path "${QFP_PYTHON_HOST_PATH}")
    set(use_pyc_in_embedding FALSE)
else()
    set(host_python_path "${Python_EXECUTABLE}")
endif()

add_custom_command(
    COMMAND ${host_python_path} -E
            "${CMAKE_CURRENT_SOURCE_DIR}/embed/embedding_generator.py"
    ...
)
```

In pseudo-cross, cmake detects different `CMAKE_SYSTEM_NAME`/`CMAKE_HOST_SYSTEM_NAME`
and sets `SHIBOKEN_IS_CROSS_BUILD=TRUE`. This causes the code to use
`${QFP_PYTHON_HOST_PATH}` instead of `${Python_EXECUTABLE}`.

The `-DPython_EXECUTABLE=` and `-DPython3_EXECUTABLE=` flags added in the
previous iteration (cross-debug/41, cross-debug/42) have **no effect** when
`SHIBOKEN_IS_CROSS_BUILD=TRUE` — the wrong branch is taken.

`QFP_PYTHON_HOST_PATH` is normally set by pyside6's superproject cmake.
When building shiboken6 standalone (i.e. not via the superproject), it is
never populated → empty → `-E: command not found`.

## Fix

```nix
# After:
"-DQFP_PYTHON_HOST_PATH=${python.pythonOnBuildForHost.interpreter}"
```

Added to `cmakeFlags` alongside the existing `Python_EXECUTABLE` flags.
Both are needed: `Python_EXECUTABLE`/`Python3_EXECUTABLE` for other cmake
`find_package(Python)` uses; `QFP_PYTHON_HOST_PATH` for the cross-mode
`embedding_generator.py` invocation specifically.
