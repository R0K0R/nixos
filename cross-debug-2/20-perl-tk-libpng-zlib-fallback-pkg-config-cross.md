# 20 — perl-Tk: libpng/zlib fallback paths wrong in cross build

**Package:** `perl5.42.0-Tk-804.036-x86_64-unknown-linux-gnu`  
**Commit:** `e9bd755`

## Symptom

```
'pkg-config libpng' failed, continue with fallback values...
'pkg-config zlib' failed, continue with fallback values...
make[1]: *** No rule to make target 'png.h', needed by 'imgPNG.o'. Stop.
```

## Root cause

`PNG/Makefile.PL` calls `pkg-config` to find libpng and zlib. In a
pseudo-cross build, `PKG_CONFIG_PATH` is set for native (BUILD) packages,
not HOST packages — so both calls fail. The fallback values are:

```perl
$libpng_cflags = '-I/usr/local/include';
$libpng_libs   = '-lpng -lm';
$zlib_cflags   = '-I/usr/local/include';
$zlib_libs     = '-lz';
```

`/usr/local/include` doesn't exist in the nix sandbox. `Tk::MakeDepend`
scans the fallback include path for `png.h`, doesn't find it, marks it as
"will be made", and make fails with "no rule to make target".

The nixpkgs cross-build patch (replacing `try_run(...)` with `if (1)`) was
already applied, forcing the "use system libpng" code path — but that makes
things worse, since it guarantees the fallback paths are used without any
compile test.

## Fix

Added four `substituteInPlace` calls to the existing cross-build `postPatch`
block in `perl-packages.nix`, replacing the fallback values with the actual
nix store paths:

```nix
substituteInPlace PNG/Makefile.PL \
  --replace-fail "\$libpng_cflags = '-I/usr/local/include';" "\$libpng_cflags = '-I${pkgs.libpng.dev}/include';" \
  --replace-fail "\$libpng_libs   = '-lpng -lm';" "\$libpng_libs   = '-L${pkgs.libpng.out}/lib -lpng -lm';" \
  --replace-fail "\$zlib_cflags = '-I/usr/local/include';" "\$zlib_cflags = '-I${pkgs.zlib.dev}/include';" \
  --replace-fail "\$zlib_libs   = '-lz';" "\$zlib_libs   = '-L${pkgs.zlib.out}/lib -lz';"
```

In Nix `''` strings, `\$foo` produces `\$foo` in the shell string; inside
double quotes the shell interprets `\$` as a literal `$`, so
`substituteInPlace` receives the literal Perl variable name as the search
string.

## Pattern

Non-pattern (pkg-config cross path isolation). Similar to the earlier
Tk `try_run` fix (#09) but a distinct failure mode — the detection is
bypassed but the wrong fallback is used.
