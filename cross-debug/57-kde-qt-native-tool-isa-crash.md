# 57 — KDE cmake native-tool ISA crash: waitpkg on AMD yulee

## Symptom

Several KDE packages abort with exit code 134 (SIGABRT) during their cmake
build step on yulee (AMD Ryzen 9900X):

```
Incompatible processor. This Qt build requires the following features:
    waitpkg
FAILED: [code=134] icons/breeze-icons.qrc ...
```

```
FAILED: [code=262] bin/docbookl10nhelper
...
Incompatible processor. This Qt build requires the following features:
    waitpkg
```

Affected packages: `breeze-icons`, `kdoctools`, and potentially any KDE package
that builds Qt-linked helper executables during its cmake phase.

## Root Cause

### cmake compiles project tools for HOST, then runs them on BUILD

In cmake cross-compilation, all executables in the project are compiled for
the **HOST** target. When the cmake build then executes those tools as
`add_custom_command` steps, they run on the **BUILD** machine.

For `breeze-icons`:
- cmake compiles `generate-symbolic-dark.cpp` and `qrcAlias.cpp` → links against
  HOST Qt6 (compiled with `-march=meteorlake`)
- cmake runs `bin/generate-symbolic-dark` and `bin/qrcAlias` to process icons

For `kdoctools`:
- cmake compiles `docbookl10nhelper.cpp` → links against HOST Qt6 (meteorlake)
- cmake runs `bin/docbookl10nhelper` to generate XSL customization files

### Qt's qCpuInit() hard-aborts on missing ISA features

Qt6Core compiled with `-march=meteorlake` enables `waitpkg` optimizations.
At library startup (`qCpuInit()`), Qt checks that the runtime CPU supports those
features:

```cpp
if (!qCpuHasFeature(waitpkg)) {
    fprintf(stderr, "Incompatible processor. This Qt build requires the following features:\n    waitpkg\n");
    abort();
}
```

**yulee is AMD Ryzen 9900X (znver3). `waitpkg` is an Intel-specific instruction
(TPAUSE/UMONITOR/UMWAIT). AMD does not support it.** Any binary linked against
HOST Qt6 (meteorlake) crashes at startup on yulee.

### Note from mk-kde-derivation.nix

The nixpkgs KDE module explicitly notes this is a FIXME:
```nix
# FIXME(later): this is wrong for cross, some of these things really need to go
# into nativeBuildInputs, but cross is currently very broken anyway, so we can
# figure this out later.
```

## Fixes

### breeze-icons — redirect to BUILD-platform derivation (nixpkgs patch)

`breeze-icons` final output is **architecture-independent** (SVG icon files +
`.rcc` binary data). We can use the BUILD-platform derivation directly. The
BUILD-platform Qt6 is generic x86_64 — no `waitpkg` optimizations — so
`generate-symbolic-dark` and `qrcAlias` build and run fine on yulee.

In `pkgs/kde/frameworks/breeze-icons/default.nix`:
```nix
if stdenv.buildPlatform != stdenv.hostPlatform
then pkgsBuildBuild.kdePackages.breeze-icons
else mkKdeDerivation { ... }
```

`pkgsBuildBuild.kdePackages.breeze-icons` evaluates the same file with
`buildPlatform == hostPlatform` → takes the `else` branch → no circular evaluation.

### kdoctools — use BUILD-platform native binaries (nixpkgs patch)

`kdoctools` has a HOST-specific library (`libKF6DocTools.so`), so we can't
replace it entirely with the BUILD-platform derivation. However, kdoctools'
cmake already has cross-compile support:

```cmake
if(CMAKE_CROSSCOMPILING AND DOCBOOKL10NHELPER_EXECUTABLE)
    add_executable(KF6::docbookl10nhelper IMPORTED GLOBAL)
    set_target_properties(KF6::docbookl10nhelper PROPERTIES
        IMPORTED_LOCATION ${DOCBOOKL10NHELPER_EXECUTABLE})
else()
    add_executable(KF6::docbookl10nhelper ALIAS docbookl10nhelper)
endif()
add_custom_command(TARGET docbookl10nhelper POST_BUILD
    COMMAND $<TARGET_FILE:KF6::docbookl10nhelper> ...)
```

The same pattern exists for `meinproc6` and `checkXML6`. When
`CMAKE_CROSSCOMPILING=TRUE` (set by nixpkgs cross cmake hook) and
`DOCBOOKL10NHELPER_EXECUTABLE` is set, cmake uses the provided path in the
POST_BUILD step instead of the just-built HOST binary. The HOST binary is still
compiled and linked (no way to skip that) but never executed.

In `pkgs/kde/frameworks/kdoctools/default.nix`:
```nix
let
  nativeKdoctools = pkgsBuildBuild.kdePackages.kdoctools.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DINSTALL_INTERNAL_TOOLS=ON" ];
  });
in mkKdeDerivation {
  extraNativeBuildInputs = [ nativeKdoctools ];
  extraCmakeFlags = [
    "-DDOCBOOKL10NHELPER_EXECUTABLE=${nativeKdoctools}/bin/docbookl10nhelper"
    "-DMEINPROC6_EXECUTABLE=${nativeKdoctools}/bin/meinproc6"
    "-DCHECKXML6_EXECUTABLE=${nativeKdoctools}/bin/checkXML6"
  ];
  ...
}
```

`INSTALL_INTERNAL_TOOLS=ON` is needed because `docbookl10nhelper` is not
installed by default (guarded by that flag in cmake). `meinproc6` and
`checkXML6` are unconditionally installed so they're available in the unpatched
BUILD-platform kdoctools `bin/`.

No circular evaluation: `pkgsBuildBuild.kdePackages.kdoctools` is evaluated
with BUILD platform stdenv (`buildPlatform == hostPlatform`), so the
`nativeKdoctools != null` branch is not taken there.

## Why the pattern is widespread

Any KDE package that:
1. Has a C++ generator tool in `tools/CMakeLists.txt`
2. Links that tool against Qt (for XML, file I/O, etc.)
3. Runs the tool as a `add_custom_command` in the same cmake build

...will fail in this pseudo-cross scenario. The proper fix would be to build
such tools via `ExternalProject_Add` using the BUILD-platform compiler, but
that requires upstream cmake changes in each KDE package.

## Files Changed

- `pkgs/kde/frameworks/breeze-icons/default.nix` — redirect to BUILD platform
  for cross builds
- `hosts/galaxybook4-pro360/default.nix` — add `kdoctools` to preferLocalBuild
  overlay; remove now-superseded `breeze-icons` and `ki18n` overlay entries

## See also

- [[55-qt6quicktools-missing-cross-downstream]] — Qt cmake tool dependency mechanism
- `mk-kde-derivation.nix` FIXME comment — upstream acknowledgement of the issue
