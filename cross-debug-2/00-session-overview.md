# Cross-Debug Session 2 — Overview

**Date:** 2026-06-22  
**Goal:** Get `nixos-rebuild switch` working for `galaxybook4-pro360`  
**nixpkgs branch:** `github:R0K0R/nixpkgs/pseudo-cross-fundamental` (F1–F14 applied)

## Setup

- BUILD = `x86_64-znver5` (yulee, AMD)
- HOST = `x86_64-meteorlake` (galaxybook4-pro360, Intel)
- Kernel: `pkgs.linuxPackages_7_1`
- Overlay location: `hosts/galaxybook4-pro360/default.nix`
- nixpkgs-contrib: `/home/r0k0r/nixpkgs-contrib` (branch `pseudo-cross-fundamental`)

## Build command

```bash
nixos-rebuild switch \
  --sudo \
  --flake /home/r0k0r/flakes/nixos#galaxybook4-pro360 \
  --option max-jobs 0 \
  --option builders-use-substitutes true \
  --builders "ssh://r0k0r@100.64.0.1 x86_64-linux,i686-linux /etc/nix/remote-builder/ssh_key 10 4 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake,gccarch-znver3"
```

## All fixes this session (chronological)

| # | Doc | Package | Where | Commits |
|---|---|---|---|---|
| 01 | [01](01-linux71-attribute-const-glibc-2.42.md) | linux-7.1 (resolve_btfids/objtool) | nixpkgs-contrib patch | `2b21ee7`→`5fc6c53` (4 iterations) |
| 02 | [02](02-linux71-hostcflags-no-macro-redefined-invalid.md) | linux-7.1 HOSTCFLAGS | nixpkgs-contrib common-flags.nix | `331f3d0`→`b9a8a34` |
| 03 | [14](14-libcbor-cmake-examples-cross.md) | libcbor | nixpkgs-contrib | `ba3bd74`, `343aa35` |
| 04 | [07](07-mime-charset-module-install-fcntl-miniperl.md) | MIME-Charset / perl miniperl | nixpkgs-contrib | `fd8ed2f`→`3f18f7e` |
| 05 | [08](08-xindy-clisp-nativebuildInputs.md) | texlive/xindy (clisp) | nixpkgs-contrib | `49ca5ce` |
| 06 | [10](10-flutter-postinstall-which-home.md) | flutter | nixpkgs-contrib | `6d38779`, `55dc8c5` |
| 07 | [09](09-perl-tk-try-run-png-detection.md) | perl-Tk (try_run PNG) | nixpkgs-contrib | `ca7b99a` |
| 08 | [11](11-ghostscript-genarch-declaration-after-statement.md) | ghostscript (GCC 15) | nixpkgs-contrib | `1d9e654`, `b4a2b19` |
| 09 | [12](12-libfprint-fprintd-cross-failures.md) | libfprint + fprintd | nixpkgs-contrib | `7050175`, `5abf119`, `b712bce`, `e488699` |
| 10 | [13](13-ispc-clangpp-plain-name-cross.md) | ispc (clang++ plain name) | nixpkgs-contrib | `c80c110`, `990c6fe` |
| 11 | [01](01-linux71-attribute-const-glibc-2.42.md) | linux-7.1 kernel build | boot.nix | `953df07` (switch to 7.1) |
| 12 | [05](05-perl-tk-png-pkg-config-pseudo-cross.md) | perl-Tk (PKG_CONFIG_PATH) | overlay default.nix | `cf7f306` |
| 13 | [04](04-html-tree-module-build-rmtree-fastcwd-newline.md) | HTML-Tree (Module::Build) | overlay default.nix | `13a5730`, `be06dae` |
| 14 | [06](06-cmake-cache-internal-vs-d-flag.md) | (observation, no commit) | — | — |
| 15 | [03](03-jasper-stdc-version-cmake-cache-internal.md) | jasper (STDC_VERSION) | overlay default.nix | `89fa405` |
| 16 | [04](04-html-tree-module-build-rmtree-fastcwd-newline.md) | Module::Build rmtree/getcwd newline (Perl 5.42) | nixpkgs-contrib perl-packages.nix | `c0f4e34`, `923ac80` |
| 17 | [20](20-perl-tk-libpng-zlib-fallback-pkg-config-cross.md) | perl-Tk PNG pkg-config fallback paths | nixpkgs-contrib perl-packages.nix | `e9bd755` |
| 18 | [21](21-dart-gcc15-fpclassify-signbit-simulator-riscv.md) | dart GCC 15 math functions (simulator_riscv.cc) | nixpkgs-contrib dart/source/default.nix | `66ef10e` |
| 19 | [22](22-libosinfo-vala-introspection-cross.md) | libosinfo Vala requires introspection (cross) | nixpkgs-contrib libosinfo/package.nix | `594ca55` |
| 20 | [23](../cross-debug-2/23-qtbase5-qfloat16-f16c-march-redefinition.md) | qtbase5 qfloat16 F16C redefinition (-march=meteorlake) | nixpkgs-contrib qt-5/modules/qtdeclarative.nix + overlay | `9eb1fdf`, `a61b5b2` |
| 21 | [24](24-qtquickcontrols5-qmlcachegen-cross.md) | qtquickcontrols5 qmlcachegen not found in cross | overlay default.nix | `771a04b` |
| 22 | [25](25-texlive-icu76-bibtexu-upmendex.md) | texlive bibtexu+upmendex ICU 76 symbol move | nixpkgs-contrib texlive/bin.nix | `cc4078ef3` |
| 23 | [26](26-qt5-setup-hook-pseudo-cross-native-host.md) | Qt5 setup hook: native+cross qtbase coexist | nixpkgs-contrib qt-5/hooks/qtbase-setup-hook.sh | `844196671` |
| 24 | [27](27-texdoc-texlua-host-binary-cross.md) | texdoc texlua HOST binary can't run on BUILD | nixpkgs-contrib texlive/tlpdb-overrides.nix | `b33bad5d0` |
| 25 | [28](28-samba-disallowed-references-pseudo-cross.md) | samba disallowedReferences BUILD python in pseudo-cross | nixpkgs-contrib samba/4.x.nix | `572e99f13` |
| 26 | cross-debug/26 | asymptote libtirpc rpc/types.h via NIX_CFLAGS_COMPILE | nixpkgs-contrib asymptote/package.nix | `35cc84ceb` |
| 27 | cross-debug/28 | basedpyright keytar npm rebuild hook timing | nixpkgs-contrib basedpyright/package.nix | `fc1b35307` |
| 28 | [30](30-basedpyright-keytar-npm-config-hook-timing.md) | basedpyright keytar: npmRebuildFlags (hook timing insight) | nixpkgs-contrib basedpyright/package.nix | `fc1b35307` |
| 29 | [29](29-mk-python-derivation-disallowed-refs-pseudo-cross.md) | mk-python-derivation disallowedReferences pseudo-cross (F13) | nixpkgs-contrib mk-python-derivation.nix | `e87d8fb67` |
| 30 | [31](31-qtbase6-cross-cxx-stdlib-h-isystem-order.md) | Qt6 qtbase cross C++ headers -isystem order (stdlib.h / c++config.h) | nixpkgs-contrib qt-6/modules/qtbase/default.nix | `fbbf81253`→`ae4f068b7` (4 iter) |

## Files modified

### nixpkgs-contrib (`/home/r0k0r/nixpkgs-contrib`)

- `pkgs/os-specific/linux/kernel/attribute-const-glibc-2.42-compat.patch` (new)
- `pkgs/os-specific/linux/kernel/common-flags.nix`
- `pkgs/os-specific/linux/kernel/build.nix`
- `pkgs/by-name/li/libcbor/package.nix`
- `pkgs/top-level/perl-packages.nix` (MIME-Charset, Tk)
- `pkgs/development/perl-modules/generic/default.nix`
- `pkgs/development/interpreters/perl/interpreter.nix` (Fcntl/File::Temp stubs)
- `pkgs/tools/typesetting/tex/texlive/bin.nix` (xindy clisp; ICU 76 -licui18n for bibtexu+upmendex)
- `pkgs/development/compilers/flutter/flutter.nix`
- `pkgs/by-name/gh/ghostscript/package.nix`
- `pkgs/by-name/li/libfprint/package.nix`
- `pkgs/by-name/fp/fprintd/package.nix`
- `pkgs/by-name/is/ispc/package.nix`
- `pkgs/top-level/perl-packages.nix` (Module::Build rmtree fix, Tk libpng/zlib paths)
- `pkgs/development/compilers/dart/source/default.nix` (GCC 15 math functions)
- `pkgs/by-name/li/libosinfo/package.nix` (Vala disabled in cross)
- `pkgs/development/libraries/qt-5/hooks/qtbase-setup-hook.sh` (pseudo-cross skip)
- `pkgs/tools/typesetting/tex/texlive/tlpdb-overrides.nix` (texdoc texlua cross guard)
- `pkgs/servers/samba/4.x.nix` (disallowedReferences pseudo-cross)
- `pkgs/by-name/as/asymptote/package.nix` (libtirpc NIX_CFLAGS_COMPILE)
- `pkgs/by-name/ba/basedpyright/package.nix` (npmRebuildFlags cross)
- `pkgs/development/interpreters/python/mk-python-derivation.nix` (disallowedReferences pseudo-cross F13)
- `pkgs/development/libraries/qt-6/modules/qtbase/default.nix` (NIX_CFLAGS_COMPILE_BEFORE cross C++ headers)

### flakes/nixos (`/home/r0k0r/flakes/nixos`)

- `hosts/galaxybook4-pro360/boot.nix` (switched to linuxPackages_7_1)
- `hosts/galaxybook4-pro360/default.nix` (overlay: perl-Tk, HTML-Tree, jasper, nodejs, qt5 qtbase+qtquickcontrols, embree EMBREE_MAX_ISA=DEFAULT)

## Pattern coverage (cross-debug catalogue)

| Pattern | Packages | Status |
|---|---|---|
| G3 (strictDeps BUILD tools) | xindy/clisp, fprintd/glib.dev | ✅ fixed in nixpkgs-contrib |
| A2-clang (plain clang++ name) | ispc | ✅ fixed per-package (.cc unwrapped) |
| B (HOST binary at BUILD configure) | libfprint tests, Tk try_run | ✅ fixed per-package |
| Non-pattern GCC 15 | ghostscript | ✅ fixed in nixpkgs-contrib |
| Non-pattern perl/canExecute | MIME-Charset and CPAN ecosystem | ✅ fixed in infrastructure |
| Non-pattern cmake try_run | Tk PNG, jasper STDC_VERSION | ✅ fixed per-package |
| Non-pattern meson exe_wrapper | libfprint | ✅ fixed per-package |
