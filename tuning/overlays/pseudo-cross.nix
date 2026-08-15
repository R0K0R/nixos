{ lib, inputs }:

/*
  Generic pseudo-cross and build-load fixes -- everything any intra-ISA
  pseudo-cross host needs, as opposed to anything about one machine's hardware.

  These lived in hosts/galaxybook4-pro360/default.nix, reachable by exactly one
  host. Most are not meteorlake-specific at all: test suites that fail under
  build-machine load (xapian, openldap, nodejs, sdl3), cross-build configure
  defects (jasper, libosinfo, qt5), GCC-15 strictness (frei0r). A second tuned
  host had no way to get any of them short of copying the file wholesale.

  A LIST of overlays, not one merged attrset: each block stays exactly as it was
  written, so this move changes where they live and nothing else.

  GUARD RENAME, the one substantive edit. Four blocks were gated on

      isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or {}).arch or "" == "meteorlake"

  which reads as "only on the laptop" but is not what it means. Its job is to
  keep the overlay off pkgsBuildBuild -- the untuned BUILD set, which carries no
  gcc.arch -- so that reaching for prev.pkgsBuildBuild inside cannot recurse.
  Written as the arch string, a cloned host silently loses every one of them.
  Written as isTuned ("this set is tuned at all"), it keeps working, which is the
  entire point of moving them here.

  The other two blocks were never guarded and still are not: they applied to
  every package set including pkgsBuildBuild, and adding a guard would newly let
  pkgsBuildBuild's xapian/openldap/nodejs run the suites they disable.
*/

[
    # Eight KF6 frameworks (kcoreaddons, knotifications, kxmlgui, ...) set
    # hasPythonBindings = true, dragging in pyside6 -- which since upstream
    # removed its withQtWebEngine toggle unconditionally builds qtwebengine
    # (full Chromium). Traced via `nix why-depends --derivation`: this was the
    # SOLE route to qtwebengine in the closure, and it appeared TWICE (host
    # cross build via knotifications, plus a second native build via
    # kf6-host-tooling -> kcmutils -> kxmlgui). The bindings exist for writing
    # KDE apps in Python; nothing installed here uses them. Forcing them off
    # through the scope's mkKdeDerivation covers all frameworks at once --
    # packages that never set hasPythonBindings produce identical args
    # (default is already false), so only the eight opted-in frameworks and
    # their dependents change hashes.
    (final: prev: {
      kdePackages = prev.kdePackages.overrideScope (kf: kp: {
        # mkKdeDerivation is an attrset with __functor (it also carries
        # kf6HostTooling); wrap the call while preserving the other attrs.
        #
        # hasPythonBindings = false alone is not enough: the frameworks'
        # own CMakeLists default BUILD_PYTHON_BINDINGS to ON (nixpkgs never
        # passes the flag -- setting hasPythonBindings merely supplies
        # shiboken6/pyside6 so the REQUIRED find_packages succeed). Removing
        # the deps without flipping the option fails configure with
        # "Could not find ... Shiboken6". Pass OFF explicitly for packages
        # that had bindings enabled.
        mkKdeDerivation = kp.mkKdeDerivation // {
          __functor =
            _self: args:
            kp.mkKdeDerivation (
              args
              // {
                hasPythonBindings = false;
              }
              // lib.optionalAttrs (args.hasPythonBindings or false) {
                extraCmakeFlags = (args.extraCmakeFlags or [ ]) ++ [ "-DBUILD_PYTHON_BINDINGS=OFF" ];
              }
            );
        };
      });
    })

    # xapian's test suite (apitest etc.) hangs indefinitely when built remotely
    # on yulee. Not a cross issue — disable checks for this host's builds only.
    (final: prev: {
      xapian_1_4 = prev.xapian_1_4.overrideAttrs (_: { doCheck = false; });

      # meson auto-disables introspection in cross builds; Vala requires
      # introspection and would error out if left enabled.
      libosinfo = prev.libosinfo.overrideAttrs (old: {
        mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Denable-vala=disabled" ];
      });

      # Sync replication tests (test*-sync*) have timing-sensitive sleeps
      # that fail under this build server's load (heavy parallel jobs, ZFS
      # sandbox, etc.) — not specific to cross builds.
      openldap = prev.openldap.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          rm -f tests/scripts/test*-sync*
        '';
      });

      # Pattern F (cross-debug/90): -march=meteorlake is ambient via NIX_CFLAGS_COMPILE.
      # Embree builds ISA-dispatch kernels (sse42, avx, avx2, avx512) each compiled with
      # ISA-specific feature flags (-msse4.2, -mavx2, -march=skylake-avx512).  The ambient
      # -march=meteorlake overrides the avx512 arch flag → AVX512 files compile as meteorlake
      # → symbol namespace confusion between ISA tiers → lld reports undefined sse42 symbols.
      # EMBREE_MAX_ISA=DEFAULT detects the native ISA from the compiler flags (meteorlake →
      # AVX2) and builds only that single ISA kernel, eliminating multi-ISA dispatch entirely.
      # lld is still used for Pattern C (hidden typeinfo across DSO; cross-debug/91).
      embree = prev.embree.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.buildPackages.lld ];
        cmakeFlags = (old.cmakeFlags or [ ]) ++ [
          "-DEMBREE_MAX_ISA=DEFAULT"
          "-DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=lld"
          "-DCMAKE_SHARED_LINKER_FLAGS=-fuse-ld=lld"
          "-DCMAKE_MODULE_LINKER_FLAGS=-fuse-ld=lld"
        ];
      });

      # Qt5's configure sets PKG_CONFIG_LIBDIR to the wrapper binary dir (not
      # where .pc files are), so pkg-config finds nothing in cross builds. MySQL
      # detection silently fails but -plugin-sql-mysql is explicitly requested,
      # causing a hard error. Qt5 is EOL; disable MySQL support for this host.
      qt5 = prev.qt5.overrideScope (_qself: qsuper: {
        qtbase = (qsuper.qtbase.override { mysqlSupport = false; }).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            # With -march=meteorlake injected, __F16C__ is always defined.
            # Qt's configure ran without -march so QT_COMPILER_SUPPORTS(F16C)==0
            # → static fallback stubs compiled at line 253 in the #else branch.
            # But QFLOAT16_INCLUDE_FAST is also defined so qfloat16_f16c.c is
            # included at line 305, defining the same functions as non-static
            # → "redefinition" error.  Add QT_COMPILER_SUPPORTS(F16C) guard.
            sed -i '/^#include "qfloat16tables.cpp"$/{n; s/#ifdef QFLOAT16_INCLUDE_FAST/#if defined(QFLOAT16_INCLUDE_FAST) \&\& QT_COMPILER_SUPPORTS(F16C)/}' src/corelib/global/qfloat16.cpp
          '';
        });

        # In pseudo-cross, qmlcachegen (from qtdeclarative.dev/bin) is not found
        # via QT_HOST_BINS (which points to qtbase, not qtdeclarative).  qtPrepareTool
        # resolves to an empty path → Makefile recipe is just "-o output.qmlc source.qml"
        # → bash: o: command not found (Error 127, ignored during build) → install step
        # tries to copy non-existent .qmlc files → fatal Error 3.
        # .qmlc files are optional ahead-of-time QML cache; strip CONFIG += qmlcache
        # so the EXTRA_COMPILERS and INSTALLS entries are never generated.
        qtquickcontrols = qsuper.qtquickcontrols.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            find . -name '*.pro' -exec sed -i 's/CONFIG += qmlcache//' {} +
          '';
        });
      });

      # jasper's CMakeLists.txt refuses to auto-detect __STDC_VERSION__ in
      # cross-compilation mode and sets the sentinel "0L" via CACHE INTERNAL
      # (which always overwrites the initial value even if a -D flag was passed).
      # Patch the sentinel to C17 (201710L) directly so the downstream check passes.
      jasper = prev.jasper.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace CMakeLists.txt \
            --replace-fail \
              'set(JAS_STDC_VERSION "0L" CACHE INTERNAL "The value of __STDC_VERSION__.")' \
              'set(JAS_STDC_VERSION "201710L" CACHE INTERNAL "The value of __STDC_VERSION__.")'
        '';
      });

      # test-performance-eventloopdelay is timing-sensitive and fails under build load.
      nodejs-slim_24 = prev.nodejs-slim_24.overrideAttrs (_: { doCheck = false; });
      nodejs_24 = prev.nodejs_24.overrideAttrs (_: { doCheck = false; });

      # testrwlock times out under build load (thread scheduling, not a bug).
      sdl3 = prev.sdl3.overrideAttrs (_: { doCheck = false; });

      # perl-Tk's PNG/Makefile.PL calls `pkg-config libpng` directly.  In
      # pseudo-cross the setup hook for libpng.dev adds to PKG_CONFIG_PATH
      # but the value isn't visible when Makefile.PL shells out.  Set it
      # explicitly so pkg-config finds the HOST libpng and generates the
      # correct Makefile (without this, it falls back to /usr/local/include
      # which doesn't exist in the sandbox, breaking texlive-scripts).
      perlPackages = prev.perlPackages.overrideScope (pself: psuper: {
        Tk = psuper.Tk.overrideAttrs (old: {
          preConfigure = (old.preConfigure or "") + ''
            export PKG_CONFIG_PATH="${final.libpng.dev}/lib/pkgconfig:''${PKG_CONFIG_PATH:-}"
          '';
        });

        # Module::Build 0.4234's delete_filetree uses the deprecated
        # File::Path::rmtree API which saves/restores cwd via Cwd::fastcwd().
        # Perl 5.42 now warns on stat with newlines in paths; something in the
        # cross build environment causes fastcwd() to return a path with a
        # trailing newline, breaking the rmtree cwd restoration.
        # buildPerlModule hard-codes "perl Build.PL; ./Build build" in
        # buildPhase. HTML-Tree also ships Makefile.PL; builder.sh's
        # preConfigure always runs "perl Makefile.PL", so we can bypass
        # Module::Build entirely by switching the build/install/check phases
        # to use make instead of ./Build.
        HTMLTree = psuper.HTMLTree.overrideAttrs (old: {
          buildPhase = ''
            runHook preBuild
            make
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            make install
            runHook postInstall
          '';
          checkPhase = ''
            runHook preCheck
            make test
            runHook postCheck
          '';
        });
      });

      # tint0r.c uses __m128 (float) as a raw 128-bit container for integer SSE
      # ops (__m128i). GCC 15 made this a hard error regardless of -std mode.
      # Drop just the tint0r filter (minor video tint effect); all others build fine.
      frei0r = prev.frei0r.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          sed -i '/tint0r/d' src/filter/CMakeLists.txt
        '';
      });
    })

    # nixfmt is Haskell; cross-compiling it drags in iserv-proxy → network (C-FFI)
    # which fails configure with the cross GCC.  Use BUILD-platform binary instead.
    # GHC doesn't autovectorize; glibc uses IFUNC, so znver5 code runs on meteorlake.
    # isTuned guard prevents recursion when overlay applies to pkgsBuildBuild.
    (final: prev:
      let
        isTuned = ((prev.stdenv.hostPlatform.gcc or { }).arch or "") != "";
      in
      lib.optionalAttrs isTuned {
        nixfmt = prev.pkgsBuildBuild.nixfmt;
      }
    )

    # qcoro calls find_package(Qt6 COMPONENTS Quick) which makes Qt6Config.cmake
    # validate each component at qtbase's prefix. nixpkgs puts qtdeclarative in a
    # separate store path, so the validation fails. qtModule.nix converts the
    # QT_ADDITIONAL_PACKAGES_PREFIX_PATH env var → cmake cache, but qcoro is not
    # a Qt module and skips that hook. Pass the variable explicitly.
    (final: prev:
      let
        isTuned = ((prev.stdenv.hostPlatform.gcc or { }).arch or "") != "";
      in
      lib.optionalAttrs isTuned {
        qt6Packages = prev.qt6Packages.overrideScope (_qpfinal: qpprev: {
          qcoro = qpprev.qcoro.overrideAttrs (old: {
            # Qt6QuickConfig.cmake calls find_dependency(Qt6QuickTools).  The
            # native tools cmake config lives in pkgsBuildBuild.qt6.qtdeclarative,
            # not the host qtdeclarative, so point cmake there explicitly.
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
              final.pkgsBuildBuild.qt6.qtdeclarative
            ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${final.qt6.qtdeclarative}"
              "-DQt6QuickTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
            ];
          });
          # kdsoap lives in qt6Packages (not top-level).  With Qt6 the code
          # generator is built as kdwsdl2cpp-qt6 but examples call kdwsdl2cpp
          # (no suffix) → command not found at build time.  Skip examples only.
          kdsoap = qpprev.kdsoap.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + ''
              sed -i '/add_subdirectory.*[Ee]xamples/d' CMakeLists.txt
            '';
          });
        });

        # rnnoise-plugin depends on webkitgtk_4_1 only because JUCE bundles a
        # WebBrowserComponent in juce_gui_extra.  The LADSPA/LV2/VST audio plugins
        # have no need for a web browser.  webkitgtk_4_1 cannot be built in a
        # pseudo-cross setup: JSC/Inspector/WTF typeinfo symbols are hidden by
        # -fvisibility=hidden and can't cross DSO boundaries (ld.bfd requires export;
        # lld also errors on STV_HIDDEN symbols in shared libs it links).
        # Fix: drop webkitgtk_4_1 from rnnoise-plugin's inputs and define
        # JUCE_WEB_BROWSER=0 so JUCE compiles without the web view backend.
        rnnoise-plugin = prev.rnnoise-plugin.overrideAttrs (old: {
          buildInputs = builtins.filter (d: d != prev.webkitgtk_4_1) (old.buildInputs or [ ]);
          # juceaide's missing bare cc/gcc on PATH used to be worked around
          # here with a pkgsBuildBuild.stdenv.cc nativeBuildInput --
          # superseded by a general fix in nixpkgs-contrib's own
          # rnnoise-plugin package.nix (commit 8de9e0f2c075), which does the
          # same thing unconditionally whenever hostPlatform != buildPlatform.
          #
          # LV2 requires juce_lv2_helper, a HOST-compiled post-processor that cmake
          # runs on the BUILD machine (yulee/znver5).  In pseudo-cross, the binary
          # is -march=meteorlake-tuned and SIGILLs on yulee.  We only need LADSPA
          # for kdenlive; disable LV2 to skip the helper entirely.
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DBUILD_LV2_PLUGIN=OFF"
          ];
          # Without LV2 the lv2/ subdir is never created; guard the move so the
          # postInstall loop doesn't fail, and create an empty lv2 output so the
          # declared output store path is populated.
          postInstall = ''
            for plugin in ladspa lxvst vst3; do
              mkdir -p ''${!plugin}/lib
              mv $out/lib/$plugin ''${!plugin}/lib/$plugin
              ln -s ''${!plugin}/lib/$plugin $out/lib/$plugin
            done
            mkdir -p $lv2/lib
          '';
          env = (old.env or { }) // { NIX_CFLAGS_COMPILE = "-DJUCE_WEB_BROWSER=0"; };
        });

        # kdsoap-ws-discovery-client's own workaround for the HOST-vs-BUILD
        # kdwsdl2cpp SIGILL (kdsoap's exported cmake target used to point at
        # the meteorlake-tuned HOST binary) is gone -- superseded by a
        # general fix in nixpkgs-contrib itself (kdsoap's own postInstall,
        # commit e93f223c8259), which patches KDSoapTargets-release.cmake at
        # the source (kdsoap) rather than in every consumer downstream.
      }
    )

    # kdePackages.breeze (v6) builds a Qt5 Breeze style plugin by referencing
    # libsForQt5.__internalKF5.kirigami2, which pulls in the KDE5 framework chain
    # and hits a qtquickcontrols2 API mismatch. We don't need the Breeze style
    # on niri; drop it from easyeffects while keeping breeze-icons.
    (final: prev:
      let isTuned = ((prev.stdenv.hostPlatform.gcc or { }).arch or "") != "";
      in lib.optionalAttrs isTuned {
        # kdePackages.breeze (v6) pulls in the KDE5 framework chain via its Qt5
        # style plugin, hitting a qtquickcontrols2 API mismatch. Not needed on niri.
        #
        # Qt6Graphs (in qtgraphs), Qt6Quick/Qt6Qml (in qtdeclarative), and
        # Qt6Quick3D (in qtquick3d) are split into separate store paths. Two cmake
        # fixes are required to build against them in pseudo-cross:
        #
        #   1. QT_ADDITIONAL_PACKAGES_PREFIX_PATH — tells Qt6Config.cmake's prefix
        #      validation that those extra prefixes are allowed for components.
        #
        #   2. _qt_additional_packages_prefix_paths (cmake CACHE var so it is global
        #      across nested find_package scopes) — Qt's internal PATHS list used by
        #      _qt_internal_find_qt_dependencies. Qt6GraphsDependencies.cmake calls
        #      that macro to find Qt6Quick/Qt6Qml, which live in qtdeclarative, not
        #      in qtbase or qtgraphs. Without this the PATHS are empty in the nested
        #      scope and Quick/Qml are not found.
        #
        # *Tools_DIR / KF6Config_DIR cache vars (Qt6QmlTools, Qt6QuickTools,
        # Qt6Quick3DTools, KF6Config) used to be pointed at pkgsBuildBuild
        # here -- superseded by a general fix in nixpkgs-contrib's own
        # easyeffects package.nix (commit 677e141342c5), which does the same
        # thing unconditionally whenever hostPlatform != buildPlatform.
        easyeffects = prev.easyeffects.overrideAttrs (old: {
          buildInputs = lib.filter (p: (p.pname or "") != "breeze") (old.buildInputs or [ ]);
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${final.qt6.qtgraphs};${final.qt6.qtdeclarative};${final.qt6.qtquick3d}"
            "-D_qt_additional_packages_prefix_paths=${final.qt6.qtgraphs}/lib/cmake;${final.qt6.qtdeclarative}/lib/cmake;${final.qt6.qtquick3d}/lib/cmake"
          ];
        });

        # zam-plugins marks itself broken for cross-builds, but pseudo-cross here is
        # x86_64→x86_64 (meteorlake tuning only), so the binaries execute fine on yulee.
        zam-plugins = prev.zam-plugins.overrideAttrs (old: {
          meta = old.meta // { broken = false; };
        });
      })

    # F8: Fresh native i686 stdenv, bypassing the pseudo-cross overlay. Pattern D.
    # Without this, pkgsi686Linux inherits the meteorlake hostPlatform overlay →
    # triple-cross (BUILD=x86_64 → HOST=i686 → TARGET=i686 pseudo-cross) which
    # breaks 32-bit compat packages (mesa i686, libgcrypt i686, etc.).
    (final: prev:
      let isTuned = ((prev.stdenv.hostPlatform.gcc or { }).arch or "") != "";
      in lib.optionalAttrs isTuned {
        pkgsi686Linux = import inputs.nixpkgs {
          localSystem = { system = "i686-linux"; };
          config = prev.config;
        };
      })
]
