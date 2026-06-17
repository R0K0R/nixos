# cross-debug/77: webkitgtk cmake fails — REGEX MATCHALL with empty CMAKE_CXX_FLAGS

## Problem

`webkitgtk-2.52.3+abi=4.1-x86_64-unknown-linux-gnu` cmake configure fails:

```
CMake Error at Source/cmake/WebKitCompilerFlags.cmake:348 (string):
  string sub-command REGEX, mode MATCHALL needs at least 5 arguments total to
  command.
Call Stack (most recent call first):
  Source/cmake/WebKitCommon.cmake:233 (include)
  CMakeLists.txt:16 (include)
```

This causes `rnnoise-plugin` (which depends on webkitgtk_4_1 for its JUCE
WebBrowserComponent GUI) to fail, which in turn causes `kdenlive` to fail when
built with the rnnoise LADSPA wrapper.

## Root cause

`WebKitCompilerFlags.cmake` line 348:

```cmake
if (NOT MSVC)
    string(REGEX MATCHALL "-fsanitize=[^ ]*" ENABLED_COMPILER_SANITIZERS ${CMAKE_CXX_FLAGS})
endif ()
```

`string(REGEX MATCHALL <regex> <output_var> <input>...)` requires at least 5
arguments (string + REGEX + MATCHALL + regex + output_var + 1 input).  When
`CMAKE_CXX_FLAGS` is empty, `${CMAKE_CXX_FLAGS}` expands to NOTHING — not an
empty string — so cmake sees only 4 arguments and errors out.

In nixpkgs builds, `CMAKE_CXX_FLAGS` starts empty; the compiler flags are set
via cc-wrapper (`NIX_CFLAGS_COMPILE`) at compile time, not via `CMAKE_CXX_FLAGS`
as a cache variable.  So this hits consistently.

## Fix

In `pkgs/development/libraries/webkitgtk/default.nix`, add to `postPatch`:

```bash
substituteInPlace Source/cmake/WebKitCompilerFlags.cmake \
  --replace-fail \
    'string(REGEX MATCHALL "-fsanitize=[^ ]*" ENABLED_COMPILER_SANITIZERS ${CMAKE_CXX_FLAGS})' \
    'string(REGEX MATCHALL "-fsanitize=[^ ]*" ENABLED_COMPILER_SANITIZERS "${CMAKE_CXX_FLAGS}")'
```

Quoting `"${CMAKE_CXX_FLAGS}"` forces cmake to treat it as an empty string
argument rather than expanding to nothing.  `REGEX MATCHALL` on an empty string
produces an empty list, which is the correct behaviour — no sanitizer flags.

## Files

- `pkgs/development/libraries/webkitgtk/default.nix` — added substituteInPlace to postPatch
