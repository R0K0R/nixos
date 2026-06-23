# 05 — perl-Tk: PNG/Makefile.PL calls `pkg-config libpng` directly

## Symptom

```
No rule to make target 'png.h', needed by 'PNG/PNG.o'. Stop.
```

or variations where the build falls back to `/usr/local/include/png.h` which
doesn't exist in the nix sandbox.

## Root cause

`perl-Tk`'s `PNG/Makefile.PL` calls `pkg-config --cflags libpng` directly in a
shell subprocess to locate libpng headers. In a native or real-cross build, the
nixpkgs `libpng.dev` setup hook populates `PKG_CONFIG_PATH` and the call succeeds.

In pseudo-cross, the `PKG_CONFIG_PATH` environment variable IS set by the setup
hook, but the value is not visible when `Makefile.PL` shells out. The pseudo-cross
`strictDeps` relaxation (F4) helps for many cases but the direct shell invocation
from Makefile.PL runs in a subprocess that doesn't inherit the modified env in the
expected way.

## Fix

Explicitly set `PKG_CONFIG_PATH` to include `libpng.dev` in the `preConfigure`
hook, using `overrideScope` to thread the change through the perlPackages fixed
point:

```nix
perlPackages = prev.perlPackages.overrideScope (pself: psuper: {
  Tk = psuper.Tk.overrideAttrs (old: {
    preConfigure = (old.preConfigure or "") + ''
      export PKG_CONFIG_PATH="${final.libpng.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
    '';
  });
});
```

The nix string interpolation `${final.libpng.dev}` resolves the HOST libpng.dev
store path at evaluation time. `''${PKG_CONFIG_PATH:-}` is a nix literal for
`${PKG_CONFIG_PATH:-}` (bash parameter expansion for "existing value or empty"),
preserving any previously set PKG_CONFIG_PATH entries.

## Cross-debug category

**Pattern E (binary side) + environment propagation.** The setup hook sets
`PKG_CONFIG_PATH` but it doesn't propagate into the subprocess spawned by Makefile.PL.
Explicit `export` in preConfigure is the standard workaround. A more fundamental fix
would be to patch perl-Tk's `PNG/Makefile.PL` to use `ExtUtils::PkgConfig` instead
of shelling out to `pkg-config` directly.
