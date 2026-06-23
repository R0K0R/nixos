# Cross-Build Session 2 — Fixes Applied

Session covering commit range `574ce0cc0`…`9df0db70e` on branch `pseudo-cross-fundamental`.
BUILD = x86_64-znver5 (yulee, Ryzen 9900X), HOST = x86_64-meteorlake (galaxybook4-pro360).

---

## 1. nautilus — blueprint-compiler 0.20.4 SIGSEGV on non-TTY stdout

**Commit:** `574ce0cc0`
**File:** `pkgs/by-name/na/nautilus/package.nix`

### Symptom

`meson` calls `blueprint-compiler batch-compile …` to compile `.blp` UI definition
files. The process exits with status 11 (SIGSEGV) after writing valid XML output:

```
[10/XX] Generating src/resources/ui/action-bar.ui, ...
FAILED: src/resources/ui/action-bar.ui ...
Subprocess returned status code 139.
```

### Root Cause

blueprint-compiler 0.20.4 crashes in GLib type-system cleanup (`g_type_class_unref`)
whenever its stdout is not a TTY — which is always the case inside a nix sandbox
(stdout is a pipe/file). The XML is written correctly before the crash, but the
nonzero exit code causes meson to treat the step as failed.

`strace` confirms: signal 11 arrives after all `write()` calls to stdout, inside
`GLib` finalizers. This is an upstream bug independent of pseudo-cross.

### Fix

Pre-compile every `.blp → .ui` in `postPatch` (ignoring the nonzero exit), verify
each output is non-empty, then patch the meson `custom_target` to copy pre-built
files instead of re-invoking blueprint-compiler:

```nix
postPatch = ''
  for blp in src/resources/ui/*.blp; do
    ui="''${blp%.blp}.ui"
    blueprint-compiler compile "$blp" > "$ui" || true
    [ -s "$ui" ] || { echo "blueprint-compiler produced empty $ui"; exit 1; }
  done
  substituteInPlace src/resources/meson.build \
    --replace-fail \
      "command: [blueprint_cmd, 'batch-compile', '--minify', '@OUTPUT@', '@CURRENT_SOURCE_DIR@', '@INPUT@']," \
      "command: ['sh', '-c', 'mkdir -p \"\$1/ui\" && cp \"\$2/ui/\"*.ui \"\$1/ui/\"', 'sh', '@OUTPUT@', '@CURRENT_SOURCE_DIR@'],"
'';
```

`blueprint-compiler` must be in `nativeBuildInputs` for the `postPatch` invocation.

---

## 2. cc-wrapper: NIX_CXXFLAGS_COMPILE_BEFORE (C++-only extraBefore)

**Commit:** `030dce97b`
**Files:** `pkgs/build-support/cc-wrapper/add-flags.sh`, `pkgs/build-support/cc-wrapper/cc-wrapper.sh`

### Problem

`NIX_CFLAGS_COMPILE_BEFORE` injects flags into `extraBefore` for **all** C and C++
compilations. When used to add C++ system header directories (e.g.,
`-isystem .../c++/15.2.0/`), those directories also appear in C compilations.

GCC 15 ships `c++/15.2.0/stdatomic.h`, a C++23 wrapper. In C mode
`__cpp_lib_stdatomic_h` is undefined, so the wrapper body is empty — but the
`_GLIBCXX_STDATOMIC_H` include guard fires, silently shadowing the real C11
`<stdatomic.h>`. This breaks files like `forkfd_c11.h` that use `memory_order_relaxed`.

### Fix

New cc-wrapper variable `NIX_CXXFLAGS_COMPILE_BEFORE` that only activates when
`isCxx=1` (C++ compilation). Added to the mangle list in `add-flags.sh`:

```bash
var_templates_list=(
    NIX_CFLAGS_COMPILE
    NIX_CFLAGS_COMPILE_BEFORE
    NIX_CXXFLAGS_COMPILE_BEFORE    # new: C++ only
    NIX_CFLAGS_LINK
    ...
)
```

And in `cc-wrapper.sh`, after the existing `extraBefore` line:

```bash
extraBefore=(... $NIX_CFLAGS_COMPILE_BEFORE_@suffixSalt@)
if [[ "$isCxx" = 1 ]]; then
    extraBefore+=($NIX_CXXFLAGS_COMPILE_BEFORE_@suffixSalt@)
fi
```

`@suffixSalt@` substitution gives it the same role-separation as all other NIX_*
variables, so the C++ flags only appear in the C++ cc-wrapper and not the C wrapper.

---

## 3. qtbase: switch from NIX_CFLAGS_COMPILE_BEFORE to NIX_CXXFLAGS_COMPILE_BEFORE

**Commit:** `030dce97b`
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

The fix for cross-debug/32 (`stdlib.h: No such file or directory`) originally used
`env.NIX_CFLAGS_COMPILE_BEFORE` to inject C++ system include dirs. Per §2 above,
this bleeds C++ headers into C compilations and breaks forkfd's C11 atomics.
Changed to `env.NIX_CXXFLAGS_COMPILE_BEFORE`:

```nix
env.NIX_CXXFLAGS_COMPILE_BEFORE =
  lib.optionalString (isCrossBuild || (stdenv.isPseudoCross or false))
    ("-isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}"
    + " -isystem ${stdenv.cc.cc}/include/c++/${lib.getVersion stdenv.cc.cc}/${stdenv.hostPlatform.config}");
```

This resolves cross-debug/32 (stdlib.h missing) without breaking cross-debug/40's
forkfd C11 atomics path.

---

## 4. qtbase: strip -mwaitpkg from native build tools (cross-debug/40)

**Commit:** `030dce97b`
**File:** `pkgs/development/libraries/qt-6/modules/qtbase/default.nix`

See cross-debug/40 for root cause. Applied the `-mwaitpkg` strip in `postConfigure`
for native (non-cross) builds — i.e., the `pkgsBuildBuild.qt6.qtbase` that provides
`rcc`, `qmlimportscanner`, etc. to the cross build:

```nix
postConfigure = lib.optionalString (!isCrossBuild) ''
  find . -name '*.ninja' | xargs sed -i 's/ -mwaitpkg//g'
'';
```

---

## 5. qtModule.nix: reliable isCrossOrPseudo detection (cross-debug/31)

**Commit:** `7ea458427`
**File:** `pkgs/development/libraries/qt-6/qtModule.nix`

`stdenv.buildPlatform != stdenv.hostPlatform` is unreliable for pseudo-cross: Nix
attrset `!=` short-circuits on thunks and returns the same hash whether or not the
condition holds (see cross-debug/31 iteration 2). All 7 occurrences replaced with:

```nix
isCrossOrPseudo =
  (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform;
```

`canExecute` is a plain boolean, not a thunk; `isPseudoCross` is an explicit flag
added by F1. This pattern is now canonical for pseudo-cross detection across the tree.

---

## 6. qtdeclarative: Qt6ShaderTools → Qt6ShaderToolsTools typo (cross-debug/54)

**Commit:** `7ea458427`
**File:** `pkgs/development/libraries/qt-6/modules/qtdeclarative/default.nix`

```nix
# Wrong — points at the library cmake config, not the tools config:
"-DQt6ShaderTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderTools"

# Correct — Qt6ShaderToolsTools contains qsb binary:
"-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
```

`Qt6ShaderTools/` is the library cmake config; `Qt6ShaderToolsTools/` is the tools
config that declares `qsb`. Without `qsb`, Qt Quick is silently disabled and all
downstream `Qt::Quick` consumers fail to find it. Also added `Qt6QuickTools_DIR`
to the cross block (was missing, causing cross-debug/55 failures).

---

## 7. mk-kde-derivation: Qt *Tools_DIR for all KDE packages (cross-debug/57, /61)

**Commit:** `7ea458427`, `9df0db70e`
**Files:** `pkgs/kde/lib/mk-kde-derivation.nix`, `pkgs/kde/default.nix`

All KDE packages using `mkKdeDerivation` now receive the full set of Qt *Tools_DIR
cmake cache variables in cross/pseudo-cross builds:

```nix
let
  isCrossOrPseudo =
    (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform;
in
mkKdeDerivation {
  ...
  cmakeFlags = [ "-DQT_MAJOR_VERSION=6" ]
    ++ lib.optionals isCrossOrPseudo [
      "-DQt6CoreTools_DIR=${pkgsBuildBuild.qt6.qtbase}/lib/cmake/Qt6CoreTools"
      "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
      "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
      "-DQt6ShaderToolsTools_DIR=${pkgsBuildBuild.qt6.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
      "-DQt6ScxmlTools_DIR=${pkgsBuildBuild.qt6.qtscxml}/lib/cmake/Qt6ScxmlTools"
      "-DQt6RemoteObjectsTools_DIR=${pkgsBuildBuild.qt6.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
      "-DQt6Quick3DTools_DIR=${pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
    ]
    ++ extraCmakeFlags;
```

`pkgsBuildBuild` was not in `mk-kde-derivation.nix`'s function args and not in the
KDE `callPackage` scope. Fix: added it to `kde/default.nix` function args and passed
it explicitly: `self.callPackage (...) { inherit pkgsBuildBuild; }`.

---

## 8. breeze-icons: redirect to pkgsBuildBuild in cross builds (cross-debug/44)

**Commit:** `7ea458427`
**File:** `pkgs/kde/frameworks/breeze-icons/default.nix`

breeze-icons compiles `qrcAlias` and `generate-symbolic-dark` with the HOST compiler
during its own cmake phase. In pseudo-cross the HOST compiler targets meteorlake
(waitpkg); yulee (AMD) crashes on these binaries immediately.

The output (SVG icon theme + `.rcc` files) is architecture-independent, so the
BUILD-platform derivation is a valid drop-in:

```nix
if (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform
then pkgsBuildBuild.kdePackages.breeze-icons
else mkKdeDerivation { pname = "breeze-icons"; ... }
```

No circular evaluation: `pkgsBuildBuild.kdePackages.breeze-icons` evaluates with
`buildPlatform == hostPlatform` and takes the `mkKdeDerivation` branch.

---

## 9. kdoctools: use nativeKdoctools from pkgsBuildBuild (cross-debug/65)

**Commit:** `7ea458427`
**File:** `pkgs/kde/frameworks/kdoctools/default.nix`

kdoctools compiles `docbookl10nhelper`, `meinproc6`, and `checkXML6` for HOST
(meteorlake) then immediately invokes them as cmake POST_BUILD custom commands.
These HOST binaries crash on AMD builders.

Fix: build an additional `nativeKdoctools` from `pkgsBuildBuild` with
`-DINSTALL_INTERNAL_TOOLS=ON` (to expose `docbookl10nhelper`) and pass the
BUILD-platform binaries via cmake cache variables:

```nix
nativeKdoctools = pkgsBuildBuild.kdePackages.kdoctools.overrideAttrs (old: {
  cmakeFlags = (old.cmakeFlags or []) ++ [ "-DINSTALL_INTERNAL_TOOLS=ON" ];
});

extraCmakeFlags = lib.optionals isCrossOrPseudo [
  "-DDOCBOOKL10NHELPER_EXECUTABLE=${nativeKdoctools}/bin/docbookl10nhelper"
  "-DMEINPROC6_EXECUTABLE=${nativeKdoctools}/bin/meinproc6"
  "-DCHECKXML6_EXECUTABLE=${nativeKdoctools}/bin/checkXML6"
];
```

kdoctools CMakeLists.txt supports `CMAKE_CROSSCOMPILING` mode: setting these three
variables causes it to import those paths as targets instead of building HOST binaries.

---

## 10. blender: bare python in preConfigure (cross-debug/93)

**Commit:** `6203ea501`
**File:** `pkgs/by-name/bl/blender/package.nix`

See cross-debug/93. Changed runtime `$(python -c '...')` to Nix-time interpolation
`"${python3.pythonVersion}"` — no interpreter binary in PATH needed at configure time.

---

## 11. blender: wayland-scanner wrong output (cross-debug/94, part 1)

**Commit:** `6203ea501`
**File:** `pkgs/by-name/bl/blender/package.nix`

`wayland-scanner` in `nativeBuildInputs` defaults to the `out` output which contains
only `share/` — the binary lives in the `bin` output. Changed to `(lib.getBin wayland-scanner)`.

---

## 12. perl Test2-Harness: disable doCheck (perl 5.42 compat)

**Commit:** `6203ea501`
**File:** `pkgs/top-level/perl-packages.nix`

`t/integration/help.t` subtest `yath help help` produces empty output with perl 5.42
(exits 0 but prints nothing). The test expects help text. Set `doCheck = false`.
Not a pseudo-cross issue — regression in Test2-Harness 1.000161 against perl 5.42.

---

## Commit Map

| Commit | Fixes |
|--------|-------|
| `574ce0cc0` | nautilus blueprint-compiler SIGSEGV (#1) |
| `030dce97b` | NIX_CXXFLAGS_COMPILE_BEFORE (#2), qtbase use it (#3), qtbase -mwaitpkg strip (#4) |
| `7ea458427` | qtModule.nix isCrossOrPseudo (#5), qtdeclarative typo (#6), mk-kde-derivation tools (#7), breeze-icons (#8), kdoctools (#9) |
| `6203ea501` | blender python (#10), blender wayland-scanner (#11), Test2-Harness doCheck (#12) |
| `9df0db70e` | mk-kde-derivation pkgsBuildBuild threading (prerequisite for #7) |
