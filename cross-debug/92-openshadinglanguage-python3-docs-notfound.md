# cross-debug/92: openshadinglanguage — Python3_EXECUTABLE-NOTFOUND in docs target

**Package:** `openshadinglanguage-x86_64-unknown-linux-gnu-1.15.3.0.drv`
**File:** `pkgs/by-name/op/openshadinglanguage/package.nix`

## Symptom

```
[ 10%] docdeep OSLQuery
bash: line 1: _Python3_EXECUTABLE-NOTFOUND: command not found
make[2]: *** [src/doc/CMakeFiles/generated_docs.dir/build.make:84: src/doc/docdeep.md.html] Error 127
make[2]: *** [src/doc/CMakeFiles/generated_docs.dir/build.make:73: src/doc/OSLQuery.md.html] Error 127
make: *** [Makefile:156: all] Error 2
```

## Root Cause

OSL's `src/doc/CMakeLists.txt` has a `generated_docs` target that calls `docdeep`, a Python
script, to generate HTML documentation. cmake resolves the interpreter via:

```cmake
find_package(Python3 COMPONENTS Interpreter)
```

In the pseudo-cross build sandbox, Python3 is not on PATH (only cross-compiled packages are
in the environment by default). cmake sets `Python3_EXECUTABLE` to the sentinel value
`_Python3_EXECUTABLE-NOTFOUND`. When the `generated_docs` target fires, the shell tries to
execute that literal string → exit 127.

This is independent of `-DUSE_PYTHON=OFF` (which was already set to disable Python bindings
for blender's use case). `USE_PYTHON` controls the Python extension module and pybind11
integration; it does not gate the docs build.

## Fix

Add `python3` to `nativeBuildInputs`. Items in `nativeBuildInputs` are pulled from
`pkgsBuildHost` (build-machine packages), so cmake's `find_package(Python3 COMPONENTS
Interpreter)` finds a working interpreter and sets `Python3_EXECUTABLE` to a real path.

```nix
nativeBuildInputs = [
  bison
  clang
  cmake
  flex
  python3  # docs/docdeep target; find_package(Python3) needs a build-machine interpreter
];
```

`python3` must also be added to the formal argument list.

## Relation to other issues

See cross-debug/87 for the earlier OSL cross-build issue (`LLVM_BC_GENERATOR` using the
cc-wrapper instead of `clang.cc`). That fix is still in place; this is a separate failure
that only surfaced once the earlier issue was resolved.
