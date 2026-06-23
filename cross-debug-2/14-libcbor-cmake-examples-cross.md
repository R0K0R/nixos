# 14 — libcbor: cmake examples fail to link in cross mode

## Symptom

```
CMake Error: No rule to make target 'examples/...' — undefined symbol: main
```
or cmake error referencing an unprocessed directory:
```
set_property(DIRECTORY examples ...) — no such directory
```

## Root cause (two iterations)

### Root cause 1: cmake cross mode fails to link example executables

libcbor's `examples/CMakeLists.txt` builds standalone executables to demonstrate
the library API. In cmake cross mode, the generated link command loses the `main`
object file path (cmake cross toolchain file interaction). Examples are not
installed and have no value in a library build.

**Round 1 fix:** `postPatch` to remove `add_subdirectory(examples)` in cross
builds. (commit `ba3bd745a`)

### Root cause 2: orphaned `set_property(DIRECTORY examples …)`

After removing `add_subdirectory(examples)`, cmake hit:
```
CMakeLists.txt:293: set_property(DIRECTORY examples ...) — directory not processed
```

`CMakeLists.txt` line 293 contains `set_property(DIRECTORY examples …)` after
the (now-removed) `add_subdirectory`. cmake requires the directory to have been
added as a cmake subdirectory before `set_property(DIRECTORY …)` references it.

**Round 2 fix:** Extended the `postPatch` sed to also strip the
`set_property(DIRECTORY examples …)` line. (commit `343aa355c`)

## Fix

```nix
postPatch = lib.optionalString (!stdenv.buildPlatform.canExecute stdenv.hostPlatform) ''
  sed -i \
    -e '/add_subdirectory(examples)/d' \
    -e '/set_property(DIRECTORY examples/d' \
    CMakeLists.txt
'';
```

## Cross-debug category

**cmake cross linking failure for executable targets** in a library build.
Standard fix: skip executables/examples in cross builds. The `set_property`
issue is a secondary cmake quirk — learned that stripping `add_subdirectory`
is not enough if there are downstream references to the removed directory.
