# cross-debug/95: blender — PYTHON_EXECUTABLE-NOTFOUND in cross build

**Package:** `blender-x86_64-unknown-linux-gnu-5.1.1.drv`
**File:** `pkgs/by-name/bl/blender/package.nix`, `nativeBuildInputs`

## Symptom

cmake configure succeeds, but build fails immediately:

```
/nix/store/.../bash: line 1: PYTHON_EXECUTABLE-NOTFOUND: command not found
make[2]: *** [.../CMakeFiles/bf_nodes_geometry_generated.dir/build.make:339:
              source/blender/nodes/geometry/register_geometry_nodes.cc] Error 127
```

cmake generates Makefile rules that call `$(PYTHON_EXECUTABLE) script.py` for code
generation. With `PYTHON_EXECUTABLE=PYTHON_EXECUTABLE-NOTFOUND`, bash tries to execute
a binary literally named `PYTHON_EXECUTABLE-NOTFOUND`.

## Root Cause

`platform_unix.cmake` calls:
```cmake
find_program(PYTHON_EXECUTABLE "python3")
```

In a native build, `python3` is in `buildInputs` → its `bin/python3` is in PATH →
`find_program` finds it.

In a **cross build**, `buildInputs` are HOST-platform packages; their binaries are NOT
added to the sandbox PATH. Only `nativeBuildInputs` binaries are in PATH. Since `python3`
is only in `buildInputs`, `find_program(PYTHON_EXECUTABLE "python3")` returns NOTFOUND.

This is the same class of issue as Pattern E in `00-pseudo-cross-fundamental-patterns.md`:
a build-time tool's binary is not in PATH in cross builds.

## Fix

Add `python3` to `nativeBuildInputs`. In a cross build, nixpkgs rewrites this to
`pkgsBuildHost.python313` (native python, runs on the BUILD machine = yulee). This puts
`python3` binary in PATH for cmake's `find_program` and for the actual code generation
during the build phase.

```nix
nativeBuildInputs = [
  cmake
  ...
  python3  # code-gen needs python3 at build time; buildInputs' bins not in PATH in cross builds
]
```

Note: this is separate from `python3Packages.wrapPython` (which only provides the
`wrapPythonPrograms` shell function, not the interpreter binary).

## Impact

This was masked by the wayland-scanner FATAL_ERROR in earlier build attempts — cmake
configure was not reaching the build phase. After fixing wayland-scanner (cross-debug/94),
this became visible as the next failure.
