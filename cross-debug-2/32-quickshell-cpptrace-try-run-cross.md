# quickshell: cpptrace try_run() fails in pseudo-cross (cmake cross-compiling mode)

**Pattern:** F14 (cmake try_run cross failure)
**Fix:** overlay `cmakeFlags += ["-DDO_NOT_CHECK_CPPTRACE_USABILITY=true"]`

## Symptom

```
CMake Error: try_run() invoked in cross-compiling mode, please set the following cache variables appropriately:
   CPPTRACE_SIGNAL_SAFE_UNWIND (advanced)
-- Cpptrace signal safe unwind test exited with: PLEASE_FILL_OUT-FAILED_TO_RUN
CMake Error at src/crash/CMakeLists.txt:48 (message):
  Cpptrace was built without CPPTRACE_UNWIND_WITH_LIBUNWIND set to true.
  Enable libunwind support in the package or set VENDOR_CPPTRACE to true when
  building Quickshell.
```

## Root Cause

`src/crash/CMakeLists.txt` calls `try_run()` to verify that the external
cpptrace was built with signal-safe unwind support:

```cmake
try_run(CPPTRACE_SIGNAL_SAFE_UNWIND CPPTRACE_SIGNAL_SAFE_UNWIND_COMP
    SOURCE_FROM_CONTENT check.cxx "
        #include <cpptrace/basic.hpp>
        int main() {
            return cpptrace::can_signal_safe_unwind() ? 0 : 1;
        }
    "
    LINK_LIBRARIES cpptrace::cpptrace
    ...
)
if (NOT CPPTRACE_SIGNAL_SAFE_UNWIND EQUAL 0)
    message(FATAL_ERROR "Cpptrace was built without CPPTRACE_UNWIND_WITH_LIBUNWIND...")
endif()
```

In pseudo-cross, `CMAKE_CROSSCOMPILING=TRUE` so cmake refuses to run the test
binary. `CPPTRACE_SIGNAL_SAFE_UNWIND` is set to the sentinel string
`PLEASE_FILL_OUT-FAILED_TO_RUN` instead of an exit code. The string is not
equal to 0 → FATAL_ERROR.

## Why the check is wrong (not just skippable)

The nixpkgs `cpptrace` package IS built with `CPPTRACE_UNWIND_WITH_LIBUNWIND=true`
(line 55 of `pkgs/by-name/cp/cpptrace/package.nix`). The `try_run()` test would
return exit code 0 on a native build. The failure is purely due to cmake's
refusal to run executables in cross mode, not a real problem.

## Fix

quickshell provides `DO_NOT_CHECK_CPPTRACE_USABILITY` precisely for cross builds
where the usability has been confirmed separately:

```nix
quickshell = prev.quickshell.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DDO_NOT_CHECK_CPPTRACE_USABILITY=true"
  ];
});
```

## Alternative: VENDOR_CPPTRACE=true

The `VENDOR_CPPTRACE=true` option makes quickshell's cmake build its own cpptrace
via `FetchContent` with `CPPTRACE_UNWIND_WITH_LIBUNWIND=true`. This avoids the
check entirely but requires internet access during `cmake --build` and would
add a bundled cpptrace to the closure alongside the external one. Avoid this.

## Infrastructure note

The F14 plan item proposed a general cmake setup hook mechanism for pre-supplying
`try_run()` answers. This package-level flag is the simplest fix for quickshell
specifically and doesn't require the infrastructure work.
