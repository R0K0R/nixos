# cross-debug/65: kpackage meinproc6 waitpkg SIGILL in cross builds

## Problem

`kpackage-x86_64-unknown-linux-gnu-6.26.0` fails during build (ninja stage):

```
FAILED: [code=134] docs/kpackagetool/kpackagetool6.1
cd /build/kpackage-6.26.0/build/docs/kpackagetool &&
  /nix/store/ckqr0a9fql2aszqk8i7qi8p7m9db7698-kdoctools-x86_64-unknown-linux-gnu-6.26.0/bin/meinproc6 \
  --stylesheet .../kde-include-man.xsl --check .../man-kpackagetool6.1.docbook
Incompatible processor. This Qt build requires the following features:
    waitpkg
```

Exit code 134 = SIGILL (illegal instruction). `meinproc6` is a HOST platform binary
compiled for x86_64+meteorlake which requires the `waitpkg` ISA extension.
AMD Ryzen 9900X (yulee builder) does not support `waitpkg` → SIGILL.

## Root cause

KDE packages that generate man pages use `KF6::meinproc6` cmake target (provided by kdoctools).
In cross builds, the cmake config for kdoctools points to HOST platform `meinproc6`,
which crashes on the AMD builder.

`KF6DocToolsConfig.cmake` (from kdoctools dev output) already has cross-compile support:
```cmake
if (CMAKE_CROSSCOMPILING AND KF6_HOST_TOOLING)
    find_file(KDOCTOOLS_TARGETSFILE KF6DocTools/KF6DocToolsToolsTargets.cmake
              PATHS ${KF6_HOST_TOOLING} ${CMAKE_CURRENT_LIST_DIR} NO_DEFAULT_PATH)
    include("${KDOCTOOLS_TARGETSFILE}")
```

When `KF6_HOST_TOOLING` is set, it loads `KF6DocToolsToolsTargets.cmake` from the
BUILD-platform kdoctools dev output instead of from the HOST kdoctools dev output.
The BUILD-platform `KF6DocToolsToolsTargets-release.cmake` defines `KF6::meinproc6`
pointing to a BUILD-platform binary (x86_64 generic, no ISA extensions) that runs fine
on yulee.

There's also a deprecated fallback using individual variables (`MEINPROC6_EXECUTABLE`,
`DOCBOOKL10NHELPER_EXECUTABLE`, `CHECKXML6_EXECUTABLE`). The existing fix in
`kdoctools/default.nix` uses this deprecated mechanism but only for kdoctools' own build.

## Fix

Added to `mk-kde-derivation.nix` cross cmakeFlags (DEPRECATED variables, intentionally):
```nix
"-DMEINPROC6_EXECUTABLE=${pkgsBuildBuild.kdePackages.kdoctools}/bin/meinproc6"
"-DCHECKXML6_EXECUTABLE=${pkgsBuildBuild.kdePackages.kdoctools}/bin/checkXML6"
```

`pkgsBuildBuild.kdePackages.kdoctools` is the BUILD-platform kdoctools (generic x86_64).
Its `bin/meinproc6` and `bin/checkXML6` are Qt-linked but compiled without `waitpkg`,
so they run fine on AMD builders.

`KF6DocToolsConfig.cmake` checks `CMAKE_CROSSCOMPILING AND MEINPROC6_EXECUTABLE` in its
else-branch (when `KF6_HOST_TOOLING` is unset) and overrides the `KF6::meinproc6` imported
target location via `set_target_properties(... IMPORTED_LOCATION ...)`. cmake build type
is `RelWithDebInfo`, so cmake falls back from `IMPORTED_LOCATION_RELWITHDEBINFO` (not set)
to `IMPORTED_LOCATION` (= BUILD-platform meinproc6). ✓

This fix applies to ALL KDE packages via mk-kde-derivation.

## Why NOT MEINPROC6_EXECUTABLE (deprecated vars)

`MEINPROC6_EXECUTABLE` was tried (gb4-71) but also failed. The cmake macros set:
```cmake
set(KDOCTOOLS_MEINPROC_EXECUTABLE "KF6::meinproc6")  # a cmake TARGET, not a path
```
`add_custom_command` resolves cmake targets using `IMPORTED_LOCATION_<CONFIG>`.
For `CMAKE_BUILD_TYPE=Release`, cmake finds `IMPORTED_LOCATION_RELEASE` (set by the
ToolsTargets file to HOST meinproc6) BEFORE falling back to `IMPORTED_LOCATION`.
The deprecated `MEINPROC6_EXECUTABLE` override only sets `IMPORTED_LOCATION` and
`IMPORTED_LOCATION_NONE` — never `IMPORTED_LOCATION_RELEASE` — so the wrong binary wins.

## KF6_HOST_TOOLING with symlinkJoin (gb4-72 approach)

`KF6_HOST_TOOLING` must be a directory containing cmake configs for ALL KDE frameworks
that check it. In a traditional install everything shares one prefix; in Nix each package
has its own store path. Solution: `symlinkJoin` the dev outputs:

```nix
kdeHostTooling = pkgsBuildBuild.symlinkJoin {
  name = "kde-host-tooling-cmake";
  paths = [
    "${pkgsBuildBuild.kdePackages.kdoctools.dev}/lib/cmake"
    "${pkgsBuildBuild.kdePackages.kconfig.dev}/lib/cmake"
  ];
};
```

`find /nix/store -name "KF6*Config.cmake" | xargs grep -l KF6_HOST_TOOLING` found only
KF6DocTools (kdoctools) and KF6Config (kconfig) in locally available cmake files.

The previous attempt (gb4-70) used only kdoctools' cmake dir → kconfig's cmake looked for
`KF6Config/KF6ConfigCompilerTargets.cmake` in that dir, failed → `KCONFIGCOMPILER_PATH-NOTFOUND`.

## meinproc6 binary analysis

The `bin/meinproc6` in HOST kdoctools is a 20KB C wrapper (NixOS makeCWrapper). It sets
XDG_DATA_DIRS etc. and execv's into `bin/.meinproc6-wrapped`, which links:
  libQt6Core.so.6, libxml2.so.16, libxslt.so.1, libexslt.so.0, libKF6Archive.so.6
Qt startup checks for `waitpkg` → "Incompatible processor" → process dies.
Same for `bin/checkXML6` → `.checkXML6-wrapped` (also Qt-linked).

## Files

- `pkgs/kde/lib/mk-kde-derivation.nix`
