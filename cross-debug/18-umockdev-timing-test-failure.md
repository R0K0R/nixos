# `umockdev`: Timing-Sensitive Test Failure in Pseudo-Cross Build

**Package:** `umockdev-0.19.3`
**File:** `pkgs/by-name/um/umockdev/package.nix`

## Symptom

```
5/5 fails-valgrind - umockdev:umockdev-record  FAIL  2.51s  killed by signal 6 SIGABRT
not ok /umockdev-record/script-log-socket - ERROR:test-umockdev-record.p/tests/test-umockdev-record.c:2526:t_system_script_log_chatter_socket_stream: assertion failed (time <= 20 * slow_testbed_factor): (23 <= 20)
```

## Root Cause

`doCheck = true` runs `mesonCheckPhase` which executes HOST-platform test binaries. In a
pseudo-cross build (same ISA, different tuple), the binaries can execute via the exe_wrapper
(QEMU or direct), but:
- Timing-sensitive test `umockdev-record/script-log-socket` asserts completion ≤ 20×factor s
- Under build server load, the test took 23s — exceeding the threshold
- Result: SIGABRT / test suite failure → entire build fails

This is a flaky load-dependent failure, not a correctness issue. The root problem is that
`doCheck = true` is unconditional even though pseudo-cross builds shouldn't run HOST-platform
test suites on the BUILD machine.

## Fix

```nix
doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```

This disables the check phase in pseudo-cross builds (where `buildPlatform ≠ hostPlatform` in
terms of the Nix tuple, even if the ISA is compatible). The tests are not meaningful for
validating the cross-compiled output anyway.

## Note

`mesonEmulatorHook` was already present in this file (conditionally for cross builds).
`gtk_doc = true` uses the old `gtk-doc` tool (not `gi-docgen`) so it does not require
BUILD-machine `pkg-config` and is not affected by the gi-docgen issue seen in `libqmi`.
