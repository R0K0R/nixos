# cross-debug/76: kdsoap-ws-discovery-client — HOST kdwsdl2cpp-qt6 requires waitpkg, crashes on yulee

## Problem

`kdsoap-ws-discovery-client-x86_64-unknown-linux-gnu-0.4.0` cmake build phase fails:

```
FAILED: [code=262] src/wsdl_ws-discovery.h
cd /build/.../build/src && \
  /nix/store/7ha9y9ajp2k153ai05b48xfkb4c0mzz3-kdsoap-x86_64-unknown-linux-gnu-2.2.0-dev/bin/kdwsdl2cpp-qt6 \
  -namespace WSDiscovery200504 ... -o .../wsdl_ws-discovery.h
Incompatible processor. This Qt build requires the following features:
    waitpkg
```

Exit code 6 from the binary; exit code 2 from make.

## Root cause

`kdsoap-ws-discovery-client` generates WSDL C++ headers at build time using
`KDSoap::kdwsdl2cpp` — a cmake IMPORTED EXECUTABLE target.  The cmake config file
`KDSoapTargets-release.cmake` hardcodes the path to this binary:

```cmake
set_target_properties(KDSoap::kdwsdl2cpp PROPERTIES
  IMPORTED_LOCATION_RELEASE "/nix/store/7ha9.../kdsoap-dev/bin/kdwsdl2cpp-qt6"
)
```

The HOST kdsoap was compiled for meteorlake (`-march=meteorlake`).  Qt's CPU
dispatcher in that binary requires `waitpkg`, an Intel-only ISA extension not
present on yulee (AMD znver5).  The binary cannot execute on the builder.

`kdsoap-ws-discovery-client` is in `kdePackages` (not `qt6Packages`).
`mkKdeDerivation` already redirects many Qt tool targets to BUILD-platform binaries
via `-DQt6CoreTools_DIR`, `-DKF6_HOST_TOOLING`, etc., but does NOT handle
`KDSoap-qt6_DIR` — KDSoap is a third-party library, not part of Qt or KDE
Frameworks.

## Fix

### Why cmake preConfigure bash approach failed first

An initial attempt modified `cmakeFlags` in a bash `preConfigure` hook:
```bash
cmakeFlags+=(-DKDSoap-qt6_DIR="$TMPDIR/kdsoap-native-cmake")
```
This corrupted `CMAKE_MODULE_PATH` because `mkKdeDerivation` accumulates cmake
flags as a list in Nix; appending to a bash array in a hook interferes with how
the KDE cmake setup hook reassembles them.  Symptom: cmake tried to `include()`
a file named literally `KDEInstallDirs6 -DQt6CoreTools_DIR=...`.

### Correct fix: runCommand derivation + Nix-side cmakeFlags

Create a small Nix derivation (`patchedKdsoapCmake`) that copies the HOST kdsoap
cmake config dir and patches the `KDSoapTargets-release.cmake` to point the
`KDSoap::kdwsdl2cpp` executable at the BUILD-platform kdsoap binary.  Then pass
`-DKDSoap-qt6_DIR=${patchedKdsoapCmake}` via the derivation's `cmakeFlags`
attribute (evaluated at nix eval time, not bash runtime):

```nix
kdePackages = prev.kdePackages.overrideScope (_kfinal: kprev: {
  kdsoap-ws-discovery-client = kprev.kdsoap-ws-discovery-client.overrideAttrs (old:
    let
      nativeKdsoap = final.pkgsBuildBuild.kdePackages.kdsoap;
      patchedKdsoapCmake = prev.runCommand "kdsoap-ws-native-cmake" { } ''
        mkdir -p $out
        cp -rT "${kprev.kdsoap.dev}/lib/cmake/KDSoap-qt6" $out
        substituteInPlace "$out/KDSoapTargets-release.cmake" \
          --replace-fail \
            "${kprev.kdsoap.dev}/bin/kdwsdl2cpp-qt6" \
            "${nativeKdsoap.dev}/bin/kdwsdl2cpp-qt6"
      '';
    in {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nativeKdsoap.dev ];
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DKDSoap-qt6_DIR=${patchedKdsoapCmake}"
      ];
    });
});
```

`-DKDSoap-qt6_DIR` takes precedence over cmake's `CMAKE_PREFIX_PATH` search, so
cmake uses the patched config.  The library targets (`KDSoap::KDSoap`,
`KDSoap::KDSoapServer`) still reference the HOST `$out/lib/*.so` paths (correct
for linking); only the executable target is redirected.

`nativeKdsoap.dev` is added to `nativeBuildInputs` so nix includes the native
binary store path in the build sandbox.

## Key scoping details

- `kdePackages.kdsoap` ≠ `qt6Packages.kdsoap` — different drvs due to spliced scope
- `kprev.kdsoap` inside `kdePackages.overrideScope` is the kdePackages-scoped kdsoap
  (the one actually used by kdsoap-ws-discovery-client)
- `final.pkgsBuildBuild.kdePackages.kdsoap` is the BUILD-platform kdePackages kdsoap
  (x86_64-linux without meteorlake tuning, can execute on yulee)
- Store paths from `${expr}` Nix interpolations are proper drv dependencies;
  not "hardcoded" — if either kdsoap changes, `patchedKdsoapCmake` reruns automatically

## Files

- `hosts/galaxybook4-pro360/default.nix` — kdePackages.overrideScope in isMeteorLakeHost block
