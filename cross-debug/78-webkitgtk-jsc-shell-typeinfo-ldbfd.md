# cross-debug/78: webkitgtk jsc shell — typeinfo for JSC::SourceProvider undefined with ld.bfd

## Problem

`webkitgtk-2.52.3+abi=4.1-x86_64-unknown-linux-gnu` build fails at link time:

```
x86_64-unknown-linux-gnu-ld.bfd: Source/JavaScriptCore/shell/CMakeFiles/jsc.dir/__/jsc.cpp.o:
  (.data.rel.ro._ZTIN3JSC29BaseWebAssemblySourceProviderE+0x10):
  undefined reference to `typeinfo for JSC::SourceProvider'
x86_64-unknown-linux-gnu-ld.bfd: Source/JavaScriptCore/shell/CMakeFiles/jsc.dir/__/jsc.cpp.o:
  (.data.rel.ro._ZTIN3JSC20StringSourceProviderE+0x10):
  undefined reference to `typeinfo for JSC::SourceProvider'
clang++: error: linker command failed with exit code 1 (use -v to see invocation)
```

This is at step ~7817/9463 — the library `libjavascriptcoregtk-4.1.so` compiled
successfully; the failure is only when linking the standalone `jsc` shell binary.

## Root cause

WebKit builds with `-fvisibility=hidden` throughout.  `JSC::SourceProvider` is a
base class whose typeinfo symbol is hidden in `libjavascriptcoregtk-4.1.so` (not
marked `JS_EXPORT_PRIVATE`).  Derived classes in `jsc.cpp` (`StringSourceProvider`,
`BaseWebAssemblySourceProvider`) hold vtable pointers that reference the base class
typeinfo.

**ld.bfd** (used in pseudo-cross builds via `x86_64-unknown-linux-gnu-binutils`)
requires that typeinfo symbols be exported from the DSO at link time.  When they
are hidden, the linker fails with "undefined reference to typeinfo".

**lld** (used in native builds) is permissive: it can resolve cross-DSO typeinfo
even when the symbol has `STV_HIDDEN` visibility, so native builds succeed.

The cmake fix from cross-debug/77 unblocked the configure phase; this is the
subsequent build phase failure.

## Fix

Replace `Source/JavaScriptCore/shell/CMakeLists.txt` with an empty file in a
postPatch, in the meteorlake overlay:

```nix
webkitgtk_4_1 = prev.webkidegtk_4_1.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    echo "" > Source/JavaScriptCore/shell/CMakeLists.txt
  '';
});
```

cmake's `add_subdirectory(shell)` still runs without error (the directory exists),
but the empty CMakeLists.txt defines no targets so the jsc binary is never built
or linked.  The runtime library and all headers/APIs build and install correctly.

### Why not `-DSHOULD_BUILD_JSC=FALSE`?

This cmake flag was tried first.  The drv hash changed (the flag was evaluated) but
the build still failed at the same step.  WebKit does not expose a stable
`SHOULD_BUILD_JSC` cmake variable that can be overridden from the command line; the
shell subdirectory is unconditionally included in JSC's cmake build.  A postPatch
that empties the shell CMakeLists.txt is more robust.

`jsc` is a developer REPL tool — it is not required by any runtime consumer of
`libjavascriptcoregtk-4.1` and is not what `rnnoise-plugin` (or any other nixpkgs
package) depends on.

## Why only abi=4.1?

`webkitgtk_4_1` is instantiated as `callPackage webkitgtk { gtk4 = pkgs.gtk3; }`
(gtk3.version = "3.x.x" < "4.0", so abiVersion = "4.1").  The abi=6.0 variant
uses the real gtk4 and builds natively (non-cross), so it uses lld and doesn't hit
this issue.

## Files

- `hosts/galaxybook4-pro360/default.nix` — webkitgtk_4_1 override in isMeteorLakeHost block
