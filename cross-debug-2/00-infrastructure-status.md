# Pseudo-Cross Infrastructure: Current Status

BUILD = x86_64-znver5 (yulee/AMD), HOST = x86_64-meteorlake (galaxybook4-pro360).
All nixpkgs patches live on branch `pseudo-cross-fundamental` at github.com/R0K0R/nixpkgs.
Cross-debug-2 = failures encountered after F-fixes applied.

---

## Implemented F-fixes

### F1 — `stdenv.isPseudoCross` flag + `NIX_IS_PSEUDO_CROSS=1` env var

**Files:**
- `pkgs/stdenv/generic/default.nix` — adds `isPseudoCross` to the stdenv attrset:
  ```nix
  isPseudoCross = hostPlatform != buildPlatform
    && hostPlatform.config == buildPlatform.config;
  ```
- `pkgs/stdenv/generic/make-derivation.nix` — exports `NIX_IS_PSEUDO_CROSS = "1"` as a
  derivation env var whenever `stdenv.isPseudoCross` is true.

**Condition:** `targetPlatform.config == hostPlatform.config && targetPrefix != ""`
**Bugs retired:** Single source of truth replacing 21+ ad-hoc `buildPlatform != hostPlatform` checks.

---

### F2 — cc-wrapper: plain compiler name symlinks → BUILD wrapper

**File:** `pkgs/build-support/cc-wrapper/default.nix`

Defines `buildCC = buildPackages.stdenv.cc or null` in the let block, then at the end of
the installPhase symlink block:

```nix
+ optionalString (targetPrefix != "" && targetPlatform.config == hostPlatform.config && buildCC != null) ''
  for binary in gcc g++ cc c++ cpp clang clang++ clang-cpp; do
    if [ -e "${buildCC}/bin/$binary" ] && [ ! -e "$out/bin/$binary" ]; then
      ln -s "${buildCC}/bin/$binary" "$out/bin/$binary"
    fi
  done
''
```

**Condition:** `targetPrefix != "" && targetPlatform.config == hostPlatform.config`
**Bugs retired:** Pattern A1 (bare `gcc`/`g++` not in PATH), A2-clang (bare `clang`/`clang++`),
G1 (qmake `system("g++ --version")` probe), cross-debug/43 (kernel modules Makefile), /82
(turbostat bare `cc`), /86 (ispc plain `clang++`), /87 (OSL `LLVM_BC_GENERATOR`), /93
(blender preConfigure bare `python`), cross-debug-2/13 (ispc two iterations).

---

### F3 — bintools-wrapper: plain binutils name symlinks

**File:** `pkgs/build-support/bintools-wrapper/default.nix`

After the regular prefixed symlink loop, adds an additional block:

```nix
${optionalString (targetPrefix != "" && targetPlatform.config == stdenvNoCC.hostPlatform.config) ''
  for binary in objdump objcopy nm strip ar ranlib as size strings readelf \
                addr2line c++filt gprof dwp elfedit; do
    if [ -e "$out/bin/${targetPrefix}''${binary}${exeSuffix}" ]; then
      ln -sf "${targetPrefix}''${binary}${exeSuffix}" "$out/bin/''${binary}${exeSuffix}"
    fi
  done
  if [ -e "$out/bin/${targetPrefix}ld${exeSuffix}" ]; then
    ln -sf "${targetPrefix}ld${exeSuffix}" "$out/bin/ld${exeSuffix}"
  fi
''}
```

**Condition:** same config check as F2
**Bugs retired:** Pattern A2-binutils: cross-debug/15 (Haskell ld.gold — partially; ld.gold still
needs adding), /39 (emacs `as` not found), /40 (emacs packages native-compile `as`), /89
(embree `check_globals` plain `objdump`).

---

### F4 — setup.sh strictDeps env-hook gate relaxed for pseudo-cross

**File:** `pkgs/stdenv/generic/setup.sh` (line ~906)

```bash
if [[ -z "${strictDeps-}" || "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
```

**Condition:** `NIX_IS_PSEUDO_CROSS=1`
**Bugs retired:** Pattern G2 (HOST setup hooks not run under strictDeps): cross-debug/37
(niri-config KDL buildInputs), /42 (KDE/Qt native host offset mismatch), /50 (qt-cmake-dev
empty `addQtModulePrefix`), /52 (Qt cmake files not in sandbox dev), /53 (Qt cmake install
libdir dev), /60 (ECM cross cmake prefix path), /73 (qcoro `QT_ADDITIONAL_PACKAGES_PREFIX_PATH`),
/97+98 (easyeffects Qt scope). Pattern G3 (wrong input class): /17 (libqmi pkg-config),
/26 (asymptote libtirpc), /28 (basedpyright keytar), /41 (fcitx5 cmake). Pattern G4 (HOST
pkg-config not in `PKG_CONFIG_PATH`): many.

---

### F5 — cmake setup-hook: `CMAKE_PROGRAM_PATH` from nativeBuildInputs

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh`

```bash
addCMakeProgramPath() {
    if [ -d "$1/bin" ]; then addToSearchPath CMAKE_PROGRAM_PATH "$1/bin"; fi
}
addEnvHooks "$targetOffset" addCMakeProgramPath
```

**Condition:** always (no pseudo-cross guard; safe for all builds)
**Bugs retired:** Pattern E binary-discovery: cross-debug/41+42 (shiboken6
`python_executable` NOTFOUND), /64 (pyside6 qtpaths), /92 (OSL python3 docs NOTFOUND),
/93+95 (blender python NOTFOUND), cross-debug-2/16 (blender wayland-scanner `find_program`),
whole "cmake `find_program()` misses nativeBuildInputs binaries" class.

---

### F6 — cc-wrapper: `-march`/`-mcpu`/`-mtune` dedup

**File:** `pkgs/build-support/cc-wrapper/cc-wrapper.sh`

```bash
if [[ "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
    _f6_march=0 _f6_mcpu=0 _f6_mtune=0
    for p in "${params[@]}"; do
        case "$p" in -march=*) _f6_march=1;; -mcpu=*) _f6_mcpu=1;; -mtune=*) _f6_mtune=1;; esac
    done
    if [[ $_f6_march == 1 || ... ]]; then
        # strip matching flag from NIX_CFLAGS_COMPILE so user's per-object flag wins
    fi
fi
```

**Condition:** `NIX_IS_PSEUDO_CROSS=1`
**Bugs retired:** Pattern F — ISA-dispatch packages: cross-debug/90 (embree ISA namespace
collision where `-march=meteorlake` overrides per-object `-march=sandybridge`), /20
(qtbase5 qfloat16 F16C redefinition), cross-debug-2/23 (same for qtbase5 session 2).

---

### F7 — lld for pseudo-cross (per-package in overlay, not global)

**File:** `hosts/galaxybook4-pro360/default.nix`

Applied per-package only — embree gets `nativeBuildInputs = [...lld]` and
`-DCMAKE_*_LINKER_FLAGS=-fuse-ld=lld`. A global lld overlay was attempted and disabled because
lld links configure test programs against HOST glibc (meteorlake), which then crash on AMD
builder during autoconf/cmake probes.

**Bugs retired (partial):** Pattern C — cross-debug/91 (embree hidden visibility ld.bfd),
/78 (webkitgtk jsc shell typeinfo — still needs per-package fix, not yet applied in cd2).

---

### F8 — fresh i686 stdenv bypassing pseudo-cross overlay

**File:** `hosts/galaxybook4-pro360/default.nix`

```nix
pkgsi686Linux = import inputs.nixpkgs {
  localSystem = { system = "i686-linux"; };
  config = prev.config // { allowUnfree = true; };
  overlays = [ ];  # no pseudo-cross overlay
};
```

**Condition:** `isMeteorLakeHost`
**Bugs retired:** Pattern D — cross-debug/85 (enable32Bit i686 libgcrypt triple-cross
failures). Prevents pseudo-cross meteorlake overlay from poisoning the i686 package set.

---

### F10 — Go: extld `LIBRARY_PATH` injection

**Files:** `pkgs/development/compilers/go/1.25.nix`, `1.26.nix`

```nix
preBuild = lib.optionalString (stdenv.hostPlatform.isGnu && stdenv.isCross) ''
  export LIBRARY_PATH=${lib.makeLibraryPath [targetCC.libc (lib.getLib targetCC.cc)]}
'';
```

Also adds `targetCC.libc` and `lib.getLib targetCC.cc` to `depsBuildTarget`.

**Condition:** `stdenv.isCross && stdenv.targetPlatform.isGnu` (covers real cross too)
**Bugs retired:** cross-debug/102 (Go bootstrap `-extld=CC_FOR_TARGET` raw gcc call bypasses
nix LIBRARY_PATH setup hooks; `ld.bfd` can't find `Scrt1.o`/`libgcc_s`).

---

### F11 — cmake: `CMAKE_PROJECT_INCLUDE` preload forwarding `-D` flags to sub-builds

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh`

Generates `$TMPDIR/nixpkgs-cmake-preload.cmake` from every `-D*=*` flag in `flagsArray`,
emitting `set(KEY "VALUE" CACHE STRING "" FORCE)` lines, then injects via
`-DCMAKE_PROJECT_INCLUDE=`. Skip list excludes: cmake infra vars (compiler paths, install
dirs), `CMAKE_FIND_USE_*`, `CMAKE_BUILD_TYPE`, `BUILD_TESTING`, **`CMAKE_CROSSCOMPILING`**
(added after it was found to break NATIVE ExternalProject sub-builds).

Also appends `$cmakeTryRunCacheVars` (space-separated `KEY=VALUE`) and reads
`${cmakeDir}/cmake-try-run-cache.cmake` from the source tree (F14 extension).

**Condition:** none (fires for all cmake builds; no-op when preload would be empty)
**Bugs retired:** Pattern B2 — cross-debug/84 (intel-graphics-compiler NATIVE FetchContent
sub-build lost cross flags). F14 extension retires cross-debug-2/32 (quickshell cpptrace
`try_run` — per-package `cmakeTryRunCacheVars`).

---

### F12 — cmake: `cmake-cross-helper-flags` forwarding hook

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh`

```bash
addCMakeCrossHelperFlags() {
    local _pkg="$1"
    if [ -f "$_pkg/nix-support/cmake-cross-helper-flags" ]; then
        while IFS= read -r _flag || [ -n "$_flag" ]; do
            if [ -n "$_flag" ]; then prependToVar cmakeFlags "$_flag"; fi
        done < "$_pkg/nix-support/cmake-cross-helper-flags"
    fi
}
addEnvHooks "$hostOffset" addCMakeCrossHelperFlags
```

HOST-offset buildInputs that write `$out/nix-support/cmake-cross-helper-flags` have those
flags automatically forwarded into every cmake consumer's `cmakeFlags`.

**Condition:** fires for every HOST buildInput package; no-op when file absent
**Bugs retired:** Pattern B (Qt/KDE class) — the general mechanism for forwarding
`Qt6*Tools_DIR`, `KF6_HOST_TOOLING` etc. without per-package boilerplate.

---

### F13 — mk-python-derivation: `disallowedReferences` relaxed for pseudo-cross

**File:** `pkgs/development/interpreters/python/mk-python-derivation.nix`

```nix
disallowedReferences = optionals (
  python.stdenv.isCross
  && !(python.stdenv.isPseudoCross or false)
) [ python.pythonOnBuildForHost ];
```

**Condition:** `isPseudoCross` disables the check
**Bugs retired:** cross-debug-2/29 — BUILD python store path leaks into HOST python package
output in pseudo-cross; same ISA so harmless but previously tripped the disallowedReferences
guard. cross-debug-2/28 (samba has its own list — patched similarly).

---

### F16 — cmake: strip redundant glibc `-isystem` after configure

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh`

```bash
if [[ "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
    find . \( -name '*.ninja' -o -name 'flags.make' \) \
        | xargs -r sed -Ei \
            's| -isystem /nix/store/[a-z0-9]{32}-glibc-[^ ]*/include||g'
fi
```

**Condition:** `NIX_IS_PSEUDO_CROSS=1`; runs after `cmake` invocation
**Bugs retired:** cross-debug/32 (qtbase cmake cross-compiler probe emits `-isystem
<glibc>/include` which reorders system headers, breaking `#include_next <stdlib.h>` in GCC's
`<cstdlib>`), cross-debug-2/31 (same for session 2 — also required F-new-A below).

---

### kf6HostTooling — unified KDE BUILD-platform cmake tool directory

**File:** `pkgs/kde/lib/mk-kde-derivation.nix`

```nix
kf6HostTooling = pkgsBuildBuild.runCommand "kf6-host-tooling" { } ''
  mkdir -p "$out"
  ln -s "${pkgsBuildBuild.kdePackages.kdoctools.dev}/lib/cmake/KF6DocTools" "$out/KF6DocTools"
  ln -s "${pkgsBuildBuild.kdePackages.kconfig.dev}/lib/cmake/KF6Config"    "$out/KF6Config"
'';
```

Passed to all `mkKdeDerivation` packages via:
```nix
"-DCMAKE_CROSSCOMPILING=TRUE"
"-DKF6_HOST_TOOLING=${kf6HostTooling}"
```
alongside all `Qt6*Tools_DIR` pointing at `pkgsBuildBuild.qt6.*`.

KDE cmake configs check `if(CMAKE_CROSSCOMPILING AND KF6_HOST_TOOLING)` and load
`<Pkg>/<Pkg>ToolsTargets.cmake` from the tooling tree, using BUILD binary paths that can
execute safely on the AMD builder.

**Condition:** `isCrossOrPseudo = (stdenv.isPseudoCross or false) || !stdenv.buildPlatform.canExecute stdenv.hostPlatform`
**Bugs retired:** cross-debug/57 (KDE Qt native tool ISA crash), /58 (Qt6CoreTools_DIR rcc),
/59 (mkKdeDerivation pkgsBuildBuild scope), /61 (mkKdeDerivation Qt tool dirs), /65
(kpackage meinproc6 waitpkg), /66 (kpackage kauth KDE host tooling), /69 (kcmutils
kcmdesktopfilegenerator waitpkg), cross-debug-2/07+09 (session 2 counterparts).

---

### F-new-A — `NIX_CXXFLAGS_COMPILE_BEFORE`: C++-only include flag variable

**File:** `pkgs/build-support/cc-wrapper/add-flags.sh` + `cc-wrapper.sh`

New env var `NIX_CXXFLAGS_COMPILE_BEFORE_<salt>` that is only prepended to the compiler
invocation when `isCxx=1`. Prevents C++ system include dirs from bleeding into C
compilations (where they shadow `<stdatomic.h>` via `#include_next`).

**Bugs retired:** cross-debug-2/02 (root discovery of the mechanism), /03 (qtbase forkfd
C11 atomics — `forkfd_c11.h` used bare `_Atomic`; C++ include dirs in
`NIX_CFLAGS_COMPILE_BEFORE` shadowed glibc `<stdatomic.h>`), /31 (qtbase6 cross C++
`stdlib.h` isystem ordering — needed both F16 and F-new-A together).

---

### F-new-B — pkg-config-wrapper: `NIX_IS_PSEUDO_CROSS` bypass for HOST pkgconfig dirs

**File:** `pkgs/build-support/pkg-config-wrapper/setup-hook.sh`

The strictDeps gate that blocked HOST buildInput pkgconfig dirs from `PKG_CONFIG_PATH` now
has an `|| "${NIX_IS_PSEUDO_CROSS-}" == "1"` bypass, identical to F4's change to setup.sh.

**Condition:** `NIX_IS_PSEUDO_CROSS=1`
**Bugs retired:** HOST `.pc` files now appear in `PKG_CONFIG_PATH` under pseudo-cross,
enabling pkg-config queries against HOST libraries. Required foundation for cross-debug-2/17
(moonlight-qt layer 1) and /05 (perl-Tk png pkg-config).

---

## Open Infrastructure Gaps

### Gap 1 — F4b: HOST `bin/` dirs not in PATH under `strictDeps=1`

**File:** `pkgs/stdenv/generic/setup.sh` — one-line addition to the `hostOffset` PATH gate:
```bash
if [[ -z "${strictDeps-}" || "$hostOffset" -le -1 || "${NIX_IS_PSEUDO_CROSS-}" == "1" ]]; then
    addToSearchPath _PATH "$pkg/bin"
```

**Status: BLOCKED** — `setup.sh` is part of the bootstrap closure. Any change invalidates
the entire pseudo-cross store (2+ day full rebuild).

**Bugs still occurring:** pyside6 `postInstall` `qtpaths6` not found (cd2/33), shiboken6
`egg_info` qtpaths (cd2/14), blender bare python in preConfigure (cd/93), OSL
`_Python3_EXECUTABLE` NOTFOUND (cd/92), flutter `which` in postInstall (cd/22). Workaround:
pass tool paths explicitly per-package or use `pkgsBuildBuild` paths.

---

### Gap 2 — Plain `pkg-config` symlink → HOST wrapper

**File:** `pkgs/build-support/pkg-config-wrapper/default.nix` — add plain `pkg-config`
symlink → `${targetPrefix}pkg-config` in `$out/bin/` when pseudo-cross, analogous to F3's
plain `ld`/`objdump` symlinks.

**Status: NOT YET IMPLEMENTED.** Per-package workarounds: moonlight-qt `preBuild` creates a
temporary symlink (cd2/17), qtwebengine sets `PKG_CONFIG_HOST` in `preConfigure` (cd2/63).

**Bugs still occurring:** moonlight-qt qmake sub-project Makefile calls bare `pkg-config`
(cd2/17 layer 2), basedpyright keytar `node-gyp` subprocess (cd2/30 layer 2), libqmi
gi-docgen meson native `pkg-config` (cd/17), qtwebengine `FindPkgConfigHost` (cd2/63),
whole Pattern G2 class (any qmake/autoconf sub-build calling bare `pkg-config`).

---

### Gap 3 — cmake: `CMAKE_PREFIX_PATH` not populated for BUILD-side (nativeBuildInputs) cmake configs

**File:** `pkgs/by-name/cm/cmake/setup-hook.sh` — add a parallel `addCMakeParams`-style
hook at `$hostOffset` (nativeBuildInputs) to populate `CMAKE_PREFIX_PATH` from BUILD-side
package cmake dirs, not just from HOST buildInputs.

**Status: NOT YET IMPLEMENTED.** Per-package workarounds: explicit `-DECM_DIR=...`,
`-DWaylandScanner_EXECUTABLE=...` etc.

**Bugs still occurring:** ECM not found in cmake builds (cross-debug/60 class — any package
with `kdePackages.extra-cmake-modules` in nativeBuildInputs), wayland-scanner
`find_package` failure (cd2/16 `find_package` path; F5 covers `find_program` but not
`find_package`).

---

### Gap 4 — KDE IMPORTED EXECUTABLE redirect convention

The `KF6_HOST_TOOLING` directory is manually maintained. No convention exists for packages
(KDE or third-party) to declare "I ship a cmake IMPORTED EXECUTABLE target that needs
a BUILD-platform redirect."

**Status: STRUCTURAL GAP.** The F12 `cmake-cross-helper-flags` mechanism provides the
propagation hook, but packages need to write the file. No uniform convention exists for cmake
IMPORTED EXECUTABLE targets specifically.

**Bugs still occurring:** kdwsdl2cpp (cd/76 — `runCommand` patching KDSoap cmake targets),
kconfig_compiler (cd/100 — `runCommand` patching KF6Config cmake targets, now replaced by
direct BUILD cmake dir), JUCE juce_lv2_helper (cd/81 — disabled with
`-DBUILD_LV2_PLUGIN=OFF`), any future KDE framework adding build-time executables.

---

### Gap 5 — `patchShebangs` cross-aware default

When `patchShebangs` (without `--build`) is called on scripts that run at configure/build
time, it patches shebangs to HOST-platform interpreters. In pseudo-cross these happen to
execute (same ISA), but in real cross they would crash. The correct default in any cross
build should be `patchShebangs --build` for scripts executed at configure/build time.

**Status: BLOCKED** — changing the default in setup.sh requires the bootstrap rebuild. Each
affected package needs an explicit `patchShebangs --build` in `postPatch`.

**Bugs still requiring per-package fixes:** libfprint meson `run_command()` (cd2/12), fprintd
gdbus-codegen (cd/24), libqmi qmi-codegen (cd/17).

---

## Upstream Compiler/Toolchain Regressions

These require per-package patches. No infrastructure change can prevent a compiler or
library from changing its API.

| Regression | Packages affected | Status |
|---|---|---|
| GCC 15: `fpclassify`/`isnan`/`signbit` removed from global C++ namespace | dart (cd/36,38, cd2/21) | Fixed per-package |
| GCC 15 + glibc 2.42: new `-Werror` triggers (`declaration-after-statement`, `-Wredundant-decls`, `-Wpacked`, `__attribute_const__` redefined) | ghostscript (cd/14, cd2/11), linux kernel (cd/25,29,31, cd2/01,02), dart close_range (cd/23, cd2/16), frei0r tint0r (cd/72) | Fixed per-package |
| Clang 21: C++20 `unhandled_exception()` template deduction | webkitgtk (cd/79) | Fixed per-package |
| ICU 76: symbols moved from `libicuuc` to `libicui18n` | texlive bibtexu/upmendex (cd/103, cd2/25) | Fixed per-package (`NIX_LDFLAGS`) |
| Perl 5.42: `Cwd::fastcwd()` trailing newline | HTML-Tree, Module::Build (cd/00 series, cd2/04,17) | Fixed per-package (switch to `buildPerlPackage`) |

---

## Genuinely Per-Package (no infrastructure fix possible)

| Class | Packages | Reason |
|---|---|---|
| Pattern B: HOST cmake IMPORTED EXECUTABLE runs on BUILD | breeze-icons, kdoctools, kdwsdl2cpp, juce_lv2_helper, texlua, kconfig_compiler | cmake has no cross-redirect primitive for `add_custom_command(POST_BUILD)`; each needs a BUILD-platform binary substitute |
| Pattern B2: NATIVE sub-build hits network/sandbox | intel-graphics-compiler FetchContent | NATIVE cmake invocation starts fresh; requires patching package's own CMakeLists.txt |
| cmake `try_run()` per-probe answers | quickshell cpptrace (cd2/32), jasper (cd2/03), Perl-Tk PNG (cd2/09) | Each probe has a unique answer; F14 provides the _mechanism_, the answer is always per-package |
| Qt5 EOL cross quirks | MySQL configure (cd2/18), qfloat16 F16C (cd2/23), setup hook check (cd2/26) | Qt5 accepts no upstream fixes |
| meson introspection/Vala cross incompatibility | libosinfo (cd2/22) | meson disables introspection in cross but doesn't cascade to Vala |
| openimageio pybind11 python cross mismatch | openimageio (cd/88) | pybind11 cmake hook mixes BUILD/HOST python paths; per-package `enablePythonEffective` guard |
| emacs libgccjit internal GCC driver | emacs-pgtk (cd/35,39,40) | libgccjit reads spec files for `as`, not nixpkgs env vars |
| GCC bootstrap stage-2 PATH | gcc (cd/101) | Per-package `--disable-bootstrap` when `isPseudoCross` |
| xapian `doCheck` hangs on ZFS | xapian (cd/67) | Test suite timing issue on yulee's ZFS; `doCheck = false` |
| BPF target includes | scx-cscheds (cd/83) | BPF is a separate compilation target outside host/build model |
| SSH ControlMaster `MaxSessions` | (yulee sshd) | sshd_config on yulee, not a package issue |
