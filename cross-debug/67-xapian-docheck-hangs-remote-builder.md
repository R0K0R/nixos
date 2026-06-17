# cross-debug/67: xapian doCheck hangs remote builds indefinitely

## Problem

gb4-73 and gb4-73b both appeared to hang with yulee idle (nothing visible in
btop). Inspecting yulee's process list revealed:

```
nixbld1   351217  3.7  0.0 100472 23136 ?  Dl  16:15  0:15 ./apitest
```

xapian's `make check` test suite (`apitest`, `internaltest`, `stemtest`,
`unittest`) was running and never completing.

## Root cause

`pkgs/development/libraries/xapian/default.nix` has `doCheck = true`.
xapian's test suite is extremely slow in sandbox conditions on yulee and
effectively hangs the build indefinitely.

## Notable discrepancy

This is NOT a cross-compilation issue. xapian is a native (BUILD-platform)
library. `doCheck = true` runs xapian's own tests as part of the build, which
works fine in normal nixpkgs CI but hangs when building remotely on yulee for
reasons not fully diagnosed (possibly sandbox I/O performance, or the test
suite has a timing-sensitive path that stalls under load).

## Fix

```nix
doCheck = false;
```

in `pkgs/development/libraries/xapian/default.nix`.

## Files

- `pkgs/development/libraries/xapian/default.nix`
