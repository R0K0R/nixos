# cross-debug/63: quickshell cpptrace try_run() fails in cross-compile mode

## Problem

`quickshell-x86_64-unknown-linux-gnu` fails cmake configure:

```
CMake Error: try_run() invoked in cross-compiling mode, please set the following cache variables appropriately:
   CPPTRACE_SIGNAL_SAFE_UNWIND (advanced)
For details see /build/source/build/TryRunResults.cmake
-- Cpptrace signal safe unwind test exited with: PLEASE_FILL_OUT-FAILED_TO_RUN
CMake Error at src/crash/CMakeLists.txt:48 (message):
  Cpptrace was built without CPPTRACE_UNWIND_WITH_LIBUNWIND set to true.
  Enable libunwind support in the package or set VENDOR_CPPTRACE to true when
  building Quickshell.
```

## Root cause

quickshell's `src/crash/CMakeLists.txt` uses `try_run()` to check whether cpptrace
was built with `CPPTRACE_UNWIND_WITH_LIBUNWIND` (libunwind signal-safe unwind).

cmake refuses to execute binaries in cross-compile mode (`stdenv.buildPlatform !=
stdenv.hostPlatform`), so `CPPTRACE_SIGNAL_SAFE_UNWIND` is left as
`PLEASE_FILL_OUT-FAILED_TO_RUN` rather than an exit code.

The check at line 48 expects the value to be `0` (exit code 0 = success = libunwind
present). Any non-zero or non-numeric string fails the check.

The nixpkgs cpptrace package IS built with libunwind:
```nix
# pkgs/by-name/cp/cpptrace/package.nix
(lib.cmakeBool "CPPTRACE_UNWIND_WITH_LIBUNWIND" true)
```

So the test would return 0 if it could run — we just need to tell cmake that.

## Fix

Added to quickshell `package.nix` cross cmakeFlags:

```nix
"-DCPPTRACE_SIGNAL_SAFE_UNWIND=0"
```

`0` = program exited with code 0 = success = libunwind support confirmed.

File: `pkgs/by-name/qu/quickshell/package.nix`

## Pattern

Any package using cmake `try_run()` in cross builds will hit this. The fix is:
- Identify what value the test would return on native build
- Set that value as a cmake cache variable in cross cmakeFlags
- cmake honors pre-set cache values and skips the try_run

See also: general cmake cross try_run pattern documented in cmake docs under
"Specifying run time results for try_run() in cross-compiling mode".
