# cross-debug/00: Pseudo-cross fundamental failure patterns

## Setup

- **buildPlatform**: `x86_64-linux` (generic — yulee, AMD znver5)
- **hostPlatform**: `x86_64-linux` + `gcc.arch = meteorlake`
- Same ISA, different micro-arch extensions (waitpkg, AVX-VNNI, etc.)
- nixpkgs treats this as a cross build because `buildPlatform != hostPlatform`
  (the platform attrsets differ in `gcc.arch`) even though the system tuple
  `x86_64-unknown-linux-gnu` is identical for both

---

## Pattern A — Plain tool names absent from cross wrappers

### The mechanism

nixpkgs wraps every compiler and binutils tool in a shell script called the
*cc-wrapper* (for compilers) and *bintools-wrapper* (for binutils). For **cross**
builds the wrapper is configured for the target triple, and it installs its
binaries **only under prefixed names**:

```
x86_64-unknown-linux-gnu-gcc
x86_64-unknown-linux-gnu-clang
x86_64-unknown-linux-gnu-clang++
x86_64-unknown-linux-gnu-objdump
x86_64-unknown-linux-gnu-nm
x86_64-unknown-linux-gnu-strip
… (no plain gcc, clang, clang++, objdump, nm, strip)
```

For **native** builds the same wrapper installs plain names only:
```
gcc
clang
clang++
objdump
nm
strip
… (no prefixed names)
```

The reason: if the cross wrapper also provided plain `gcc`, it would shadow
the build platform's own `gcc` and confuse build tools that call `gcc` meaning
"compile for the build machine."

In **pseudo-cross** (same tuple, different `gcc.arch`) nixpkgs still activates
the full cross machinery. Every CC and binutils wrapper in the build environment
is cross-configured and provides only prefixed names. Build systems that
call `clang++`, `objdump`, or `gcc` by their plain name silently get "command
not found".

### Two sub-forms

**A1 — C/C++ compiler (cc/gcc/g++/c++)**

cmake `project()` or a Makefile tries to locate `cc` or `gcc`. cmake logs
"No CMAKE_C_COMPILER could be found" or a Makefile step exits 127.

Fix: add `pkgsBuildBuild.stdenv.cc` to `nativeBuildInputs`. The build-platform
native wrapper provides plain `cc`/`gcc` names because for it that IS the
target, with no shadowing concern.

Instances: cross-debug/80 (JUCE juceaide), cross-debug/82 (turbostat)

**A2 — Specific tool called by name within the build (clang++, objdump, …)**

A build system hardcodes a specific tool name:
- cmake `set(CLANGPP_EXECUTABLE ${llvmPackages.clang}/bin/clang++)` → no
  such file (wrapper provides only `…/bin/x86_64-unknown-linux-gnu-clang++`)
- cmake script `execute_process(COMMAND objdump …)` → empty output because
  `objdump` is not in PATH; downstream `string(REPLACE)` then crashes with
  an arity error
- Any script that invokes `nm`, `strip`, `ar`, etc. by plain name

Fix: use the **raw** (unwrapped) LLVM/binutils binary, which always has plain
names in both native and cross contexts:
- For clang/clang++: `llvmPackages.clang.cc` instead of `llvmPackages.clang`
  (`.cc` is the actual `clang` binary, not the wrapper script)
- The raw binary lacks the cc-wrapper's `-isystem` header injections;
  compensate with `env.CPATH = "${stdenv.cc.libc_dev}/include"`
- For cmake scripts that run tools like `objdump` and can tolerate failure:
  guard against empty output (the script is usually advisory, not required)

Instances: cross-debug/86 (ispc clang++), cross-debug/87 (OSL LLVM_BC_GENERATOR),
cross-debug/89 (embree objdump in check_globals.cmake)

### The upstream fix

This is a single nixpkgs-wide fix in `bintools-wrapper.sh` / `cc-wrapper.sh`:
when `hostPlatform.config == buildPlatform.config` (same triple, only `gcc.arch`
differs), the cross wrapper should also install plain-name symlinks. It's safe
in this specific case because the "build machine" and "host machine" run the
same ISA; there is no actual shadowing risk. PR #526112 proposes this for `ld`;
it should be extended to all tools. Until then, per-package workarounds apply.

---

## Pattern B — HOST-compiled build-time executable runs on BUILD machine

**What happens**: A package compiles a helper tool (code generator, post-processor,
validator) for the HOST (meteorlake). cmake then tries to execute it on the BUILD
machine (yulee, znver5) as a custom command during the build phase.

**Symptom**: SIGILL (illegal instruction) because -march=meteorlake enables
`waitpkg` and similar extensions that znver5 doesn't implement. Or "command not
found" (exit 127) if cmake emits the cmake target alias name instead of the
resolved binary path when cross-compilation is detected.

**Why it happens**: cmake's `add_custom_command(COMMAND target)` resolves to the
BUILD output path of that target, which is a HOST binary. When the build and host
systems differ, cmake has no mechanism to automatically substitute a BUILD-platform
version of the tool.

**Fix pattern** (choose one):
1. Find and pass the BUILD-platform equivalent via `-D<Tool>_DIR=…` pointing at
   `pkgsBuildBuild.<pkg>`.
2. Disable the feature that requires the helper (e.g., `-DBUILD_LV2_PLUGIN=OFF`).
3. Override the cmake imported target to point at the BUILD binary.

Instances: cross-debug/76 (kdwsdl2cpp-qt6 SIGILL), cross-debug/81 (juce_lv2_helper),
cross-debug/100 (easyeffects kconfig_compiler_kf6 SIGILL),
cross-debug/103 Fix 2 (texlive texlua SIGILL in postUnpack/postFixup)

**Sub-variant B2 — cmake NATIVE sub-build can't inherit parent cache**: Some packages
invoke cmake in a NATIVE sub-build (e.g. via `ExternalProject_Add` or a nested
`add_subdirectory`). The NATIVE sub-build starts with a fresh cmake cache and does not
inherit `-D…` flags from the parent. If it then uses `FetchContent` or network fetches
expecting those flags to suppress them, it will try to reach the network (blocked in the
Nix sandbox). Fix: pass the necessary cache variables via a cmake preload file
(`CMAKE_PROJECT_INCLUDE`) or patch the NATIVE sub-build's `CMakeLists.txt` to skip the
network step.

Instance: cross-debug/84 (intel-graphics-compiler FetchContent)

---

## Pattern C — Linker symbol visibility mismatch (ld.bfd vs lld)

**What happens**: A package builds with `-fvisibility=hidden` throughout.
A base class's typeinfo or vtable symbol is hidden in a shared library but
referenced by an object that links against it. `ld.bfd` (the GNU linker, used
in pseudo-cross via the prefixed `x86_64-unknown-linux-gnu-ld.bfd`) requires
these symbols to be exported; it fails with "undefined reference to typeinfo."

**Why cross-specific**: In a native build, `ld.gold` or `lld` is often the
default linker and tolerates hidden base-class typeinfo in DSOs (it resolves
them lazily). In pseudo-cross, nixpkgs selects `ld.bfd` for the target because
it is the binutils default. The same source builds fine natively with lld.

**Fix**: force `lld` as the linker for the package, or patch the upstream
visibility annotations.

Instance: cross-debug/78 (webkitgtk jsc shell typeinfo)

---

## Pattern D — Third cross layer (i686 / enable32Bit)

**What happens**: `hardware.graphics.enable32Bit = true` causes NixOS to build
i686 variants of Mesa and its dependencies. In a normal x86_64 build this is
one cross layer (x86_64 build → i686 host). In our setup it becomes a double
cross (znver5 build → meteorlake pseudo-cross → i686 target), which exposes
test failures and configure errors that neither the single-cross nor native
codepath hits.

**Fix**: disable `enable32Bit` on the pseudo-cross host, or skip tests for
the i686 package tier (`doCheck = false` in the overlay).

Instance: cross-debug/85 (enable32Bit i686 libgcrypt tests)

---

## Pattern E — nativeBuildInput `.pc` file invisible to cmake's `pkg_check_modules`

**What happens**: cmake configure fails with a "library not found" SEND_ERROR or
FATAL_ERROR for a package that IS in nativeBuildInputs (its binary is in PATH).

**Why it happens**: Two compounding issues:

**Issue 1 — binary not in PATH**: nixpkgs packages with multiple outputs (`out`, `bin`, `dev`,
etc.) default to the `out` output. Some tools put the binary in a separate `bin` output and
`out` contains only documentation or shared data. When `nativeBuildInputs = [ foo ]` and `foo`
defaults to an output with no binary, the tool is never in PATH. Check with `ls $(nix-build
'<nixpkgs>' -A foo.out)/`. Fix: use `(lib.getBin foo)` = `foo.bin or foo` in nativeBuildInputs.

**Issue 2 — `.pc` file not in `PKG_CONFIG_PATH`**: even when the binary IS in PATH,
`pkg_check_modules` can still fail. In nixpkgs cross builds, pkg-config search paths split:
- `PKG_CONFIG_PATH` — HOST-platform libraries (buildInputs)
- `PKG_CONFIG_PATH_FOR_BUILD` — BUILD-platform tools (nativeBuildInputs)

cmake's `pkg_check_modules(<prefix> <name>)` calls the `pkg-config` binary, which reads
`PKG_CONFIG_PATH` only → nativeBuildInputs' `.pc` files are invisible.

A preConfigure approach of `dirname(dirname(which tool))` to compute the prefix for
`PKG_CONFIG_PATH` fails when the binary and `.pc` file are in separate nix outputs
(`-bin` vs `-dev`) — they have different store paths.

**Why not a global fix**: Merging `PKG_CONFIG_PATH_FOR_BUILD` into `PKG_CONFIG_PATH` would
cause cmake to pick up BUILD-platform library paths for HOST linking (wrong rpaths, wrong
sonames, possible ABI mismatch). It's unsafe as a blanket change and must be per-package.

**Fix pattern**: Patch the cmake file (via `patches`) to add `execute_process(COMMAND sh -c
"which <name>")` fallbacks at both check points (presence check and path lookup).

```cmake
# After pkg_check_modules(<prefix> <name>):
if(NOT <prefix>_FOUND)
  execute_process(
    COMMAND sh -c "which <name>"
    RESULT_VARIABLE _ws_which_result
    OUTPUT_QUIET ERROR_QUIET
  )
  if(_ws_which_result EQUAL 0)
    set(<prefix>_FOUND TRUE)
  endif()
endif()

# After pkg_get_variable(<VAR> <name> <field>) for executable path:
if(NOT <VAR>)
  execute_process(
    COMMAND sh -c "which <name>"
    OUTPUT_VARIABLE <VAR>
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE _ws_which_result
    ERROR_QUIET
  )
  if(NOT _ws_which_result EQUAL 0)
    unset(<VAR>)
  endif()
endif()
```

**Why `execute_process` not `find_program`**: nixpkgs's cmake setup hook puts nativeBuildInputs'
prefixes in `NIXPKGS_CMAKE_PREFIX_PATH` (NOT `CMAKE_PREFIX_PATH`) and does not populate
`CMAKE_PROGRAM_PATH`. cmake's `find_program` therefore cannot see nativeBuildInput binaries
via cmake's internal search (CMAKE_PROGRAM_PATH, CMAKE_PREFIX_PATH/bin, etc.). The only
remaining path for `find_program` is the `PATH` environment variable (step 5). But
`NO_CMAKE_FIND_ROOT_PATH` alone is insufficient if cmake's SYSTEM path searching is limited.
`execute_process(COMMAND sh -c "which ...")` directly invokes the shell which uses PATH
unconditionally — completely reliable regardless of cmake's cross-compilation mode settings.

**Diagnostic**: pkg_check_modules fails → set_and_warn_library_found SEND_ERROR or
FATAL_ERROR for a tool whose binary IS in PATH (e.g., `which wayland-scanner` succeeds).
`find_program(X tool)` even with `NO_CMAKE_FIND_ROOT_PATH` returns empty because
nixpkgs cmake hook doesn't populate `CMAKE_PROGRAM_PATH` from nativeBuildInputs.

**Known occurrences:**
- `blender/package.nix`: `wayland-scanner` — fixed by `wayland-scanner-fallback.patch`
  (cross-debug/94)

---

## Pattern F — Ambient `-march=` from cross wrapper poisons ISA dispatch

**What happens**: The pseudo-cross GCC wrapper appends `-march=meteorlake` to
`NIX_CFLAGS_COMPILE` for every compilation unit, predefining `__AVX2__`, `__AVX__`, etc.
across the entire build. Packages that use preprocessor-selected ISA namespaces (e.g.
`namespace sse42 { … }`, `namespace avx { … }`, `namespace avx2 { … }`) find that every
translation unit is compiled with the full meteorlake feature set: all ISA-dispatch macros
evaluate to `avx2`, so all namespaces map to `avx2::`. Link-time references to `sse42::Foo`
or `avx::Bar` — from static libs compiled to be ISA-generic — are then undefined.

**Why cross-specific**: In a native build the compiler default matches the runtime ISA, so
only the highest supported namespace is built. In pseudo-cross the GCC wrapper injects
`-march=meteorlake` unconditionally; per-object `-march=sse4.2` flags become additive
overrides, not replacements, and the ISA selection macros still see the ambient defines.

**Fix**: Disable the lower ISA cmake targets via package cmake flags. On meteorlake (which
always has AVX2) these code paths are dead at runtime anyway.

```nix
cmakeFlags = [
  "-DEMBREE_ISA_SSE2=OFF"
  "-DEMBREE_ISA_SSE42=OFF"
  "-DEMBREE_ISA_AVX=OFF"
  # AVX2 and AVX-512 remain ON — meteorlake always supports them
];
```

**Diagnostic**: hundreds of linker errors `undefined reference to 'pkg::sse42::Foo'` or
`pkg::avx::Bar'` when the package uses an ISA dispatch namespace pattern. The pattern is
distinctive: every undefined symbol shares the same namespace prefix for a lower ISA tier.

Instance: cross-debug/90 (embree ISA namespace collision)

---

## Pattern G — qmake pseudo-cross (toolchain, pkg-config, QMAKEPATH)

qmake build systems hit three distinct failures under pseudo-cross, all requiring a
coordinated `preConfigure` block. Unlike cmake (which reads `CMAKE_*` variables) qmake
reads the build environment at mkspec load time — before any `QMAKE_CXX` command-line
overrides take effect.

**G1 — bare compiler names absent at mkspec load time** (variant of A1)

`toolchain.prf` is loaded during qmake's mkspec phase and probes `gcc`, `g++`, `cc`, `c++`
by plain name via `system()`. At that point the PATH has not yet been modified by any
command-line arg. The prefixed wrappers (`x86_64-unknown-linux-gnu-gcc`) are in PATH but
bare `gcc` is not. Failure: `Project ERROR: Cannot run compiler 'g++'. Output: ...`.

Fix: symlink all prefixed compiler and binutils names to bare names in a scratch directory
prepended to PATH before qmake runs.

**G2 — bare `pkg-config` absent** (variant of A1/E)

`strictDeps = true` in pseudo-cross skips the HOST pkg-config wrapper's setup hook, so bare
`pkg-config` is not in PATH. qmake's `pkgConfigExecutable()` in `qt_functions.prf` calls
`system("pkg-config --exists <lib>")` to probe sub-project deps (`openssl`, `sdl2`, …).
With no `pkg-config` in PATH the check silently fails with exit code 1.

Fix: symlink the BUILD `pkg-config` wrapper as bare `pkg-config` in the scratch directory.
The BUILD wrapper already handles HOST lookups: when `NIX_PKG_CONFIG_WRAPPER_TARGET_HOST_*`
is set, `accumulateRoles()` in `add-flags.sh` merges `PKG_CONFIG_PATH` (where nixpkgs setup
hooks place HOST `.pc` files) into `PKG_CONFIG_PATH_<platform>` before invoking the
underlying `pkgconf` binary.

**G3 — HOST Qt module dev outputs not in QMAKEPATH** (variant of E)

The qtbase-dev setup hook registers `qmakePathHook` in `envBuildHostHooks`; this hook is
called for each buildInput with a `mkspecs/` subdirectory and adds it to `QMAKEPATH`. Under
`strictDeps`, env hooks for HOST buildInputs are skipped, so only the BUILD-side qtbase
paths end up in `QMAKEPATH`. Sub-project qmake runs (which inherit the environment from
`make`) fail with `Project ERROR: Unknown module(s) in QT: quick quickcontrols2 svg`.

Fix: in `preConfigure`, iterate over all HOST Qt module dev outputs and prepend those with a
`mkspecs/` directory to `QMAKEPATH`.

**Combined preConfigure template**:

```nix
preConfigure =
  lib.optionalString (stdenv.buildPlatform != stdenv.hostPlatform) (
    let
      qtHostMods =
        [ qt6.qtdeclarative.dev qt6.qtsvg.dev ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [ qt6.qtwayland.dev ];
    in
    ''
      cross_bin=$TMPDIR/cross-bin
      mkdir -p "$cross_bin"
      for tool in gcc g++ cc c++ ar as ld nm ranlib strip objcopy objdump; do
        src="${stdenv.cc}/bin/${stdenv.cc.targetPrefix}$tool"
        [ -f "$src" ] && ln -sf "$src" "$cross_bin/$tool"
      done
      ln -sf ${pkg-config}/bin/pkg-config "$cross_bin/pkg-config"   # G2
      export PATH="$cross_bin:$PATH"
      for _qtmod in ${lib.concatStringsSep " " (map toString qtHostMods)}; do   # G3
        [ -d "$_qtmod/mkspecs" ] && export QMAKEPATH="$_qtmod''${QMAKEPATH:+:$QMAKEPATH}"
      done
    ''
  );
```

Instance: `pkgs/by-name/mo/moonlight-qt/package.nix` (no separate cross-debug file)

**G4 — cmake Qt multi-prefix broken when Qt env hooks skipped**

`Qt6Config.cmake` (from qtbase) discovers modules in other store paths via
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH`. The nixpkgs Qt cmake setup hook populates
this variable automatically for packages that have Qt in their `buildInputs`, but
under `strictDeps` the HOST Qt's setup hook is skipped for non-Qt packages.
`find_package(Qt6 COMPONENTS Graphs)` then fails: Qt6Graphs lives in a separate
store path from qtbase, so cmake reports "Expected Config file at qtbase/.../Qt6Graphs
does NOT exist" even though Qt6Graphs IS in `buildInputs`.

A further complication: `Qt6Config.cmake` stores the prefix list in a LOCAL cmake
variable `_qt_additional_packages_prefix_paths`, which is invisible in the nested
`function scope` created when cmake calls `find_package(Qt6Graphs)` →
`Qt6GraphsDependencies.cmake` → `_qt_internal_find_qt_dependencies`. The result
is that transitive Qt dependencies (e.g. Qt6Quick needed by Qt6Graphs) are not
found even after `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` is set.

Fix: pass both as cmake cache variables (so they are globally visible):
```nix
cmakeFlags = [
  "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=<path1>;<path2>;..."
  "-D_qt_additional_packages_prefix_paths=<path1>/lib/cmake;<path2>/lib/cmake;..."
];
```
The `__qt_internal_collect_additional_prefix_paths` function has an early-return
guard (`if(DEFINED "${out_var}") return()`) that sees the cache entry and skips
recomputing, making the cache value effective in all nested scopes.

Instances: cross-debug/97 (easyeffects Qt6Graphs prefix), cross-debug/98 (nested
cmake scope visibility)

**G5 — Qt `*Tools_DIR` cmake vars point to HOST qt, but tools live in BUILD qt**

Qt cmake dependency files (`Qt6*Dependencies.cmake`) call
`_qt_internal_find_tool_dependencies` for each module, which calls
`find_package(Qt6<Mod>Tools ...)`. The `PATHS` searched are derived from the
HOST qtdeclarative/qtquick3d cmake directories. However, `Qt6QmlTools`,
`Qt6QuickTools`, `Qt6Quick3DTools` are BUILD-platform code-generation tools and
live only in the BUILD-platform qt packages — the HOST qt package has no `*Tools/`
cmake config dir.

Fix: pass cmake cache variables pointing to the BUILD-platform qt:
```nix
nativeBuildInputs = [ pkgsBuildBuild.qt6.qtdeclarative pkgsBuildBuild.qt6.qtquick3d ];
cmakeFlags = [
  "-DQt6QmlTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
  "-DQt6QuickTools_DIR=${pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
  "-DQt6Quick3DTools_DIR=${pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
];
```

Instance: cross-debug/99 (easyeffects Qt6QmlTools/QuickTools/Quick3DTools)

**G-overlay — Pseudo-cross overlay pulls in incompatible Qt5 chain**

When an overlay guarded by `isMeteorLakeHost` (or similar) applies only to the
HOST package set, it can inadvertently pull in a Qt5 KDE framework chain via a
transitive dependency. If the Qt5 packages in the HOST context have version
mismatches not present in an unmodified nixpkgs build (e.g., different
`qtquickcontrols2` API), the build fails with Qt5 C++ API errors.

Fix: filter the offending package from `buildInputs` in the overlay override:
```nix
buildInputs = lib.filter (p: (p.pname or "") != "breeze") (old.buildInputs or []);
```

Instance: cross-debug/96 (easyeffects kdePackages.breeze pulls Qt5 KDE chain)

---

## Why pseudo-cross is harder than real cross

In a real cross build (e.g., x86_64 → aarch64), the system tuples differ, so:
- cmake knows `CMAKE_CROSSCOMPILING=TRUE` and uses `find_program(... ONLY_CMAKE_FIND_ROOT_PATH)`
- Makefiles usually have explicit `CROSS_COMPILE=aarch64-linux-gnu-` prefix logic
- Developers test these paths

In pseudo-cross (same tuple, different march), cmake sees identical system names
and may not set `CMAKE_CROSSCOMPILING` at all, or sets it inconsistently.
Build systems that special-case "am I cross-compiling?" can't tell. The result
is a mixed state: nixpkgs applies cross logic (separate wrappers, separate
package sets) but the build system doesn't expect it.

---

## Quick diagnostic guide

| Symptom | Pattern | Likely fix |
|---|---|---|
| "No CMAKE_C_COMPILER" | A1 | add `pkgsBuildBuild.stdenv.cc` to nativeBuildInputs |
| `make: *** Error 127` at compile step | A1 | add `pkgsBuildBuild.stdenv.cc`, or set `makeFlags = ["CC=…"]` |
| `/bin/clang++: No such file or directory` in cmake | A2 | use `llvmPackages.clang.cc` for that cmake flag |
| cmake script `string REPLACE requires at least four arguments` | A2 | the preceding `execute_process` tool is absent; guard against empty output |
| `pkg-config: command not found` in configure | A1 | add `pkgsBuildBuild.pkg-config` to nativeBuildInputs |
| cmake "X not found" and `which X` fails | E | binary not in PATH: use `(lib.getBin pkg)` in nativeBuildInputs |
| cmake "X not found" but `which X` succeeds | E | `.pc` in `PKG_CONFIG_PATH_FOR_BUILD` only; patch cmake with `execute_process(sh -c "which …")` fallback |
| SIGILL during build on yulee | B | use `pkgsBuildBuild.<pkg>` for that tool |
| cmake target alias "command not found" | B | disable format/feature or redirect cmake `_DIR` |
| cmake NATIVE sub-build tries network/FetchContent | B2 | NATIVE sub-build has fresh cmake cache; pass preload file or patch to suppress network |
| Linker typeinfo/vtable errors (`STV_HIDDEN`) | C | use lld, or fix upstream visibility annotations |
| i686 test failures (`enable32Bit`) | D | i686 is a third cross layer; disable `doCheck` for i686 pkgs or drop `enable32Bit` |
| hundreds of `undefined reference to 'pkg::sse42::Foo'` | F | ambient -march poisons ISA namespace; disable lower ISA cmake targets |
| qmake "Cannot run compiler 'g++'" | G1 | preConfigure: symlink prefixed compiler names as bare names in scratch PATH dir |
| qmake "openssl development package not found" (sub-project) | G2 | preConfigure: symlink BUILD pkg-config wrapper as bare `pkg-config` |
| qmake "Unknown module(s) in QT: quick svg …" | G3 | preConfigure: prepend HOST `qt*.dev` paths to QMAKEPATH |
| cmake "Expected Config file at qtbase/.../Qt6Graphs does NOT exist" | G4 | set `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` and `_qt_additional_packages_prefix_paths` as cmake cache vars |
| cmake "Qt6Graphs found but Qt6Quick could not be found" | G4 | `_qt_additional_packages_prefix_paths` is LOCAL in Qt6Config scope; must pass as cmake `-D` cache var |
| cmake "missing: Qt6QmlTools_DIR" | G5 | *Tools live in BUILD-platform qt; pass `-DQt6QmlTools_DIR=…` pointing at `pkgsBuildBuild.qt6.*` |
| ICU 76+ linker: `undefined reference to 'ucol_openRules_76'` | — | ABI change; `env.NIX_LDFLAGS = "-licui18n"` for affected packages (texlive upmendex/bibtexu) |
| HOST script SIGILL in postUnpack/postFixup (texlua, etc.) | B | guard with `lib.optionalString (buildPlatform == hostPlatform)` |
| `clisp: command not found` in configure or build | E | clisp is a BUILD-time tool; add to `nativeBuildInputs` (nixpkgs rewrites to `pkgsBuildHost.clisp`) |
| GCC stage-2 configure: "C++ compiler cannot create executables" | A | `depsBuildBuild.gcc` in PATH shadows cross wrapper in stage-2 sub-configure; pass `--disable-bootstrap` (`isPseudoCross` fix in configure-flags.nix) |
| Go link: "cannot find Scrt1.o" or "cannot find -lgcc_s" | A | Go `-extld` calls raw gcc (not cc-wrapper); set `LIBRARY_PATH` in `preBuild` for pseudo-cross |
| ttfautohint GUI: Qt/GTK not found in cross | — | GUI is not needed cross; `enableGUI ? (buildPlatform == hostPlatform)` |
