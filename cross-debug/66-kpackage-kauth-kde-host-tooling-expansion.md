# cross-debug/66: KF6_HOST_TOOLING must cover all 4 KDE frameworks

## Problem

After gb4-72 added kdoctools+kconfig to `kdeHostTooling` symlinkJoin,
`libplasma-x86_64-unknown-linux-gnu-6.6.5` failed cmake configure:

```
-- Found KF6Package: ... (Required is at least version "6.6.0")
CMake Error ...: Could not find KF6Package/KF6PackageToolsTargets.cmake in
  ${KF6_HOST_TOOLING}
-- KPACKAGE_TARGETSFILE: KPACKAGE_TARGETSFILE-NOTFOUND
```

## Root cause

`KF6PackageConfig.cmake` (from kpackage) ALSO checks `KF6_HOST_TOOLING`:

```cmake
if (CMAKE_CROSSCOMPILING AND KF6_HOST_TOOLING)
    find_file(KPACKAGE_TARGETSFILE KF6Package/KF6PackageToolsTargets.cmake
              PATHS ${KF6_HOST_TOOLING} NO_DEFAULT_PATH)
    include("${KPACKAGE_TARGETSFILE}")
```

`kdeHostTooling` only contained kdoctools + kconfig cmake dirs, so
`KF6Package/KF6PackageToolsTargets.cmake` was not found.

Similarly, `KF6AuthConfig.cmake` checks for `KF6Auth/KF6AuthToolsTargets.cmake`.

## All KDE frameworks that check KF6_HOST_TOOLING

Found by searching all KF6*Config.cmake files in /nix/store:

| Framework   | File searched for                              |
|-------------|------------------------------------------------|
| KF6DocTools | `KF6DocTools/KF6DocToolsToolsTargets.cmake`    |
| KF6Config   | `KF6Config/KF6ConfigCompilerTargets.cmake`     |
| KF6Package  | `KF6Package/KF6PackageToolsTargets.cmake`      |
| KF6Auth     | `KF6Auth/KF6AuthToolsTargets.cmake`            |

## Fix

Expanded `kdeHostTooling` symlinkJoin in `mk-kde-derivation.nix` to include
all 4 frameworks:

```nix
kdeHostTooling = if stdenv.buildPlatform != stdenv.hostPlatform
  then pkgsBuildBuild.symlinkJoin {
    name = "kde-host-tooling-cmake";
    paths = [
      "${pkgsBuildBuild.kdePackages.kdoctools.dev}/lib/cmake"
      "${pkgsBuildBuild.kdePackages.kconfig.dev}/lib/cmake"
      "${pkgsBuildBuild.kdePackages.kpackage.dev}/lib/cmake"
      "${pkgsBuildBuild.kdePackages.kauth.dev}/lib/cmake"
    ];
  }
  else null;
```

## Discovery method

```bash
find /nix/store -name "KF6*Config.cmake" | xargs grep -l "KF6_HOST_TOOLING"
```

Returns distinct hits for kdoctools, kconfig, kpackage, kauth dev outputs.
No other KDE frameworks in the local store check this variable.

## Files

- `pkgs/kde/lib/mk-kde-derivation.nix`
