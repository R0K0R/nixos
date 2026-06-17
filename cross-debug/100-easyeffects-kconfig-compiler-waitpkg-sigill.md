# 100 — easyeffects: kconfig_compiler_kf6 HOST binary SIGILLs on yulee (waitpkg)

## Package
`easyeffects` 8.2.1

## Symptom
cmake configure succeeds but the build phase fails immediately on many targets:

```
[33/424] Generating easyeffects_db.h, easyeffects_db.cpp
FAILED: [code=262]
cd /build/source/build/src && \
  /nix/store/waczzkypf9…-kconfig-x86_64-unknown-linux-gnu-6.26.0/libexec/kf6/kconfig_compiler_kf6 \
  .../easyeffects_db.kcfg .../easyeffects_db.kcfgc -d /build/source/build/src/
Incompatible processor. This Qt build requires the following features:
    waitpkg
```

Exit code 262 = SIGILL (4) via shell exit encoding (256 + 6? actually it's
the signal exit).  `waitpkg` is an Intel Meteor Lake instruction set extension
not present on yulee (AMD znver5).

## Root cause
`KF6ConfigCompilerTargets-release.cmake` in the HOST `kconfig.dev` cmake
package hard-codes the HOST binary paths as `IMPORTED_LOCATION_RELEASE`:

```cmake
set_target_properties(KF6::kconfig_compiler PROPERTIES
  IMPORTED_LOCATION_RELEASE
    ".../kconfig-x86_64-unknown-linux-gnu-6.26.0/libexec/kf6/kconfig_compiler_kf6"
)
```

cmake uses `KF6::kconfig_compiler` as a cmake IMPORTED target to invoke
`kconfig_compiler_kf6` during the build phase (processing `.kcfg` files for
each easyeffects plugin).  The binary is compiled for meteorlake (HOST) but
runs on yulee (AMD) — SIGILL.

Same root cause as #76 (kdsoap kdwsdl2cpp) and #65 (kpackage meinproc6).

## Fix
Create a patched copy of the KF6Config cmake dir with both binary paths
replaced by their native (pkgsBuildBuild) equivalents, then point
`-DKF6Config_DIR` at the patched dir:

```nix
let
  nativeKconfig = final.pkgsBuildBuild.kdePackages.kconfig;
  patchedKconfigCmake = prev.runCommand "kconfig-native-cmake" { } ''
    mkdir -p $out
    cp -rT "${prev.kdePackages.kconfig.dev}/lib/cmake/KF6Config" $out
    substituteInPlace "$out/KF6ConfigCompilerTargets-release.cmake" \
      --replace-fail \
        "${prev.kdePackages.kconfig}/libexec/kf6/kconfig_compiler_kf6" \
        "${nativeKconfig}/libexec/kf6/kconfig_compiler_kf6" \
      --replace-fail \
        "${prev.kdePackages.kconfig}/libexec/kf6/kconf_update" \
        "${nativeKconfig}/libexec/kf6/kconf_update"
  '';
in {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nativeKconfig ];
  cmakeFlags = (old.cmakeFlags or [ ]) ++ [
    "-DKF6Config_DIR=${patchedKconfigCmake}"
  ];
}
```

Both `kconfig_compiler_kf6` AND `kconf_update` are patched because
`KF6ConfigCompilerTargets-release.cmake` imports both as IMPORTED targets, and
cmake validates the file existence for all of them at load time.

## Affected files in the cmake package
`KF6Config/KF6ConfigCompilerTargets-release.cmake` — contains both binary paths.

## Note on kconf_update
`kconf_update` is typically run post-install by users (upgrading config files),
not during the build.  It is patched here because cmake's IMPORTED target
file-existence check at configure time would fail if the file path points to a
meteorlake binary that cmake validates as present — and to be safe if any build
step invokes it.
