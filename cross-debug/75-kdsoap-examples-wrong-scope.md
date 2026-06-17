# cross-debug/75: kdsoap examples fail — package is in qt6Packages not top-level

## Problem

`kdsoap-x86_64-unknown-linux-gnu-2.2.0` build fails:

```
make[2]: *** [examples/helloworld_client/.../build.make:82: .../wsdl_helloworld.h] Error 127
make[1]: *** [...] Error 2
```

Exit code 127 = command not found.  The examples' cmake rules invoke `kdwsdl2cpp`
(no suffix) but with Qt6 the binary is installed as `kdwsdl2cpp-qt6`.

## Root cause

Two issues compounded:

### 1. Overlay targeting wrong scope

The initial fix placed `kdsoap = prev.kdsoap.overrideAttrs (...)` at the TOP LEVEL
of the overlay.  But `kdsoap` is NOT a top-level nixpkgs attribute — it lives in
`qt6Packages`:

```
pkgs/top-level/qt6-packages.nix:62:  kdsoap = callPackage ../development/libraries/kdsoap { };
```

The top-level `prev.kdsoap` doesn't exist (nix eval: "Did you mean gsoap?"), so the
override silently added an undefined attribute to the package set.  The actual kdsoap
derivation was unchanged and kept failing.

### 2. Binary renamed for Qt6

`kdsoap/default.nix` installs the code generator as `kdwsdl2cpp-qt6` when
`isQt6 = true`.  The examples' cmake rules call it as `kdwsdl2cpp` (no suffix).
Exit code 127 is `command not found`.

## Fix

Move the override to `qt6Packages.overrideScope` (same scope as the qcoro fix):

```nix
qt6Packages = prev.qt6Packages.overrideScope (_qpfinal: qpprev: {
  ...
  kdsoap = qpprev.kdsoap.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i '/add_subdirectory.*[Ee]xamples/d' CMakeLists.txt
    '';
  });
});
```

The examples are skipped entirely; the main library and `kdwsdl2cpp-qt6`
tool both build and install correctly.

## Note on kdePackages.kdsoap

`kdePackages` merges `qt6Packages` at construction time but also builds its own
spliced variant of kdsoap (different drv hash).  `kdePackages.kdsoap` does not
exhibit the examples failure — likely because its kdePackages build environment
sets up cmake differently.  The `qt6Packages.kdsoap` override only affects
`qt6Packages` scope consumers (e.g. things that pull from qt6-packages.nix
directly).

## Files

- `hosts/galaxybook4-pro360/default.nix` — kdsoap in qt6Packages.overrideScope
