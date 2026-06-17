# cross-debug/69: KF6::kcmdesktopfilegenerator waitpkg SIGILL (kcmutils)

## Problem

`fcitx5-configtool-x86_64-unknown-linux-gnu-5.1.13` fails during build:

```
Incompatible processor. This Qt build requires the following features:
   waitpkg
make[2]: *** [src/kcm/CMakeFiles/kcm_fcitx5-kcm-desktop-gen.dir/build.make:70:
              src/kcm/CMakeFiles/kcm_fcitx5-kcm-desktop-gen] Aborted (core dumped)
```

## Root cause

`KF6KCMUtilsMacros.cmake` defines `kcmutils_generate_desktop_file()` which adds:

```cmake
add_custom_target(${kcm_target}-kcm-desktop-gen
    COMMAND KF6::kcmdesktopfilegenerator ${IN_FILE} ${OUT_FILE}
    DEPENDS ${IN_FILE})
```

`KF6::kcmdesktopfilegenerator` is a Qt-linked HOST binary. cmake resolves it
via `IMPORTED_LOCATION_RELEASE` (set by `KF6KCMUtilsToolingTargets-release.cmake`
to the HOST kcmutils binary). HOST binary + AMD builder = waitpkg SIGILL.

`KF6KCMUtilsConfig.cmake` DOES check `KF6_HOST_TOOLING` (like kdoctools, kconfig,
kpackage, kauth). This was missed in cross-debug/66 because the kcmutils-x86_64
dev output wasn't in the local store at the time of the search.

## Fix

1. Added `pkgsBuildBuild.kdePackages.kcmutils.dev/lib/cmake` to `kdeHostTooling`
   symlinkJoin in `mk-kde-derivation.nix` (fixes all KDE packages).

2. Added a duplicate `kdeHostTooling` symlinkJoin + `-DKF6_HOST_TOOLING=` flag
   directly in `fcitx5-configtool.nix` (standalone package, not built via
   mk-kde-derivation).

## Updated KDE frameworks checking KF6_HOST_TOOLING (5 total)

| Framework   | File searched for                                |
|-------------|--------------------------------------------------|
| KF6DocTools | `KF6DocTools/KF6DocToolsToolsTargets.cmake`      |
| KF6Config   | `KF6Config/KF6ConfigCompilerTargets.cmake`       |
| KF6Package  | `KF6Package/KF6PackageToolsTargets.cmake`        |
| KF6Auth     | `KF6Auth/KF6AuthToolsTargets.cmake`              |
| KF6KCMUtils | `KF6KCMUtils/KF6KCMUtilsToolingTargets.cmake`    |

## Discovery note

Run after adding new HOST KDE packages to the build to catch new frameworks:
```bash
find /nix/store -name "KF6*Config.cmake" -path "*x86_64-unknown*" | \
  xargs grep -l "KF6_HOST_TOOLING" | \
  sed 's|.*nix/store/[^/]*/||' | sort -u
```

## Files

- `pkgs/kde/lib/mk-kde-derivation.nix`
- `pkgs/tools/inputmethods/fcitx5/fcitx5-configtool.nix`
