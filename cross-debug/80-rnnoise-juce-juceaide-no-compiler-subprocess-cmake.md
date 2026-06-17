# cross-debug/80: rnnoise-plugin — JUCE juceaide subprocess cmake can't find compiler

## Problem

`rnnoise-plugin-x86_64-unknown-linux-gnu-1.10` fails early in the build:

```
CMake Error at .../Modules/CMakeDetermineSystem.cmake:...
  CMake Error: Failed to configure juceaide —
  No CMAKE_C_COMPILER could be found.
```

The JUCE build system compiles a native code-generation tool called `juceaide`
using a nested cmake invocation (a cmake `ExternalProject` or subprocess
`execute_process`).  That subprocess cmake launches with an empty `PATH` (or
close to it) and searches for compilers by their plain names: `cc`, `gcc`,
`c++`, `g++`.

## Root cause

In a pseudo-cross build (buildPlatform=x86_64-linux, hostPlatform=meteorlake),
nixpkgs' cross cc-wrapper wraps the compiler as
`x86_64-unknown-linux-gnu-gcc` / `x86_64-unknown-linux-gnu-g++`.  **Plain
`cc` and `gcc` symlinks are NOT created** — the wrapper intentionally omits
them to avoid shadowing the BUILD-platform native compiler.

`juceaide` must be compiled for the BUILD platform so it can run during the
build (it generates JUCE boilerplate headers).  JUCE spawns a separate cmake
process to configure and build it; that subprocess never sees the cross
cc-wrapper names and reports "No CMAKE_C_COMPILER could be found."

## Fix

Add `pkgsBuildBuild.stdenv.cc` (the BUILD-platform native GCC wrapper) to
`nativeBuildInputs`.  The native wrapper does provide plain `cc`/`gcc`
symlinks, so the juceaide subprocess cmake finds a compiler:

```nix
rnnoise-plugin = prev.rnnoise-plugin.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
    final.pkgsBuildBuild.stdenv.cc
  ];
  ...
});
```

Fix is in the `isMeteorLakeHost`-guarded `qt6Packages` block in
`hosts/galaxybook4-pro360/default.nix` (same block as qcoro, kdsoap,
rnnoise-plugin).

## Notes

- Same class of problem as cross-debug/76 (kdwsdl2cpp SIGILL): a build-time
  executable compiled for the wrong platform.  Here the compiler is missing
  entirely; in 76 the binary runs but faults.
- `JUCE_WEB_BROWSER=0` (also applied to rnnoise-plugin, see context in
  cross-debug/81) must be set alongside this fix to remove the webkitgtk_4_1
  dependency that triggers the typeinfo DSO issue.

## Files

- `hosts/galaxybook4-pro360/default.nix` — `nativeBuildInputs` override for
  `rnnoise-plugin`
