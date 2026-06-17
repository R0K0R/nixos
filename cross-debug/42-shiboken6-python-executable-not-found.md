# shiboken6: cmake Python3_EXECUTABLE empty in cross build — embedding_generator fails

**Package:** `shiboken6-x86_64-unknown-linux-gnu-6.11.0`
**File:** `pkgs/development/python-modules/shiboken6/default.nix`

## Symptom

```
FAILED: [code=127] libshiboken/embed/signature_bootstrap_inc.h libshiboken/embed/signature_inc.h
cd /build/…/libshiboken && -E /build/…/embedding_generator.py --cmake-dir … --use-pyc FALSE
sh: line 1: -E: command not found
```

## Root Cause

`embedding_generator.py` is invoked from a cmake `add_custom_command` via:
```cmake
COMMAND ${Python3_EXECUTABLE} -E ${embedding_generator_py} --cmake-dir ...
```

With `Python3_EXECUTABLE` empty, the resulting shell command becomes just `-E script.py`,
which bash reports as "command not found" (exit code 127).

**Why is `Python3_EXECUTABLE` empty?**

cmake's `FindPython3` module searches for the Python interpreter using `find_program`.
When `CMAKE_CROSSCOMPILING` is TRUE (set automatically when the cross-compilation flags
are passed), cmake's `find_program` restricts its search to `CMAKE_FIND_ROOT_PATH` (the
target sysroot) by default.  There is no target sysroot in our sandbox, so cmake finds
the development headers from the cross Python (`python3-x86_64-unknown-linux-gnu-3.13.12`)
but cannot locate the executable — it is not inside the root path.

cmake log confirms:
```
-- Python_Interpreter_FOUND:     FALSE
-- Python_EXECUTABLE:      
-- Python_Development_FOUND:     TRUE
-- Python_LIBRARIES: /nix/store/…-python3-x86_64-unknown-linux-gnu-3.13.12/lib/libpython3.13.so
```

The `nativeBuildInputs` adds `python.pythonOnBuildForHost.withPackages(…)` to PATH,
so the build-platform Python IS available — cmake just doesn't search PATH when
`CMAKE_CROSSCOMPILING` is TRUE.

## Fix

Explicitly pass the build-platform Python executable via cmakeFlags:

```nix
"-DPython3_EXECUTABLE=${python.pythonOnBuildForHost.interpreter}"
```

This bypasses cmake's cross-compilation search restriction and points directly to the
native Python3 that can run `embedding_generator.py` on the build machine.

Applied to `pkgs/development/python-modules/shiboken6/default.nix`.

## Notes

- The cross Python (`python3-x86_64-unknown-linux-gnu-3.13.12`) only uses
  `x86-64-baseline` ISA — it actually runs on yulee (Ryzen). The issue is purely that
  cmake won't search PATH for it when cross-compiling.
- cmake detects `CMAKE_CROSSCOMPILING=TRUE` because `CMAKE_SYSTEM_NAME/PROCESSOR`
  were set explicitly in the nixpkgs cmake setup hook for cross builds.
