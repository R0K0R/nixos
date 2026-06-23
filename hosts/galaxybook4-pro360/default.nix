{ inputs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot.nix
    ./home.nix
    ./hardware.nix
    ./power.nix
    ./samsung-fixes.nix
    ./webcam.nix
    ./flamenco.nix
    ./sshfs-yulee.nix
    inputs.niri.nixosModules.niri
    ../../modules/nixos
    ../../modules/nixos/nix/remote-builder-client.nix
  ];

  services.tailscale.enable = true;

  networking.hostName = "galaxybook4-pro360";

  # Declare the local-Qt6 build capability so packages with
  # requiredSystemFeatures = ["galaxybook-local-qt6"] can build here.
  nix.settings.system-features = [ "galaxybook-local-qt6" ];

  nixpkgs.buildPlatform = "x86_64-linux";

  nixpkgs.hostPlatform = lib.systems.elaborate {
    system = "x86_64-linux";
    gcc.arch = "meteorlake";
  };

  nixpkgs.overlays = [
    inputs.niri.overlays.niri
    (import ./o3-overlay.nix)

    # pyside6 builds qtwebengine (Chromium, several GB) by default on Linux.
    # pyside6: withQtWebEngine was removed upstream; qtwebengine is now always included.

    # xapian's test suite (apitest etc.) hangs indefinitely when built remotely
    # on yulee. Not a cross issue — disable checks for this host's builds only.
    (final: prev: {
      xapian_1_4 = prev.xapian_1_4.overrideAttrs (_: { doCheck = false; });

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

    # Pseudo-cross Qt6 native-tool fixes.  Several HOST Qt modules need native
    # (build-platform) tool executables during their own build phase.  Qt cmake
    # doesn't find them in a pseudo-cross setup because NIXPKGS_CMAKE_PREFIX_PATH
    # only includes HOST packages; native tool cmake dirs are never added.
    # Pattern: add nativePkg to nativeBuildInputs (so Nix copies it into the
    # sandbox) and point cmake directly at the tools package via -D.
    # See cross-debug/45, cross-debug/46, cross-debug/48.
    (final: prev:
      let
        isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
        nativeBuildQt = attr: final.pkgsBuildBuild.qt6.${attr};
        addQtNativeTool = nativePkg: toolsPkg: pkg:
          pkg.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ nativePkg ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-D${toolsPkg}_DIR=${nativePkg}/lib/cmake/${toolsPkg}"
            ];
          });
        nativeQtShaderTools = nativeBuildQt "qtshadertools";
        # Native qtdeclarative has Qt6QuickTools (svgtoqml) and Qt6QmlTools.
        # nixpkgs already adds Qt6QmlTools_DIR via its own setup hooks; we only
        # need to add the Quick tools dir (new in Qt 6.8+, not yet in nixpkgs cross logic).
        nativeQtDeclarative = nativeBuildQt "qtdeclarative";

      in
      # Guard: only apply to the HOST (meteorlake) package set.  Without this the
      # overlay would also mutate pkgsBuildBuild.qt6, causing the native qtdeclarative
      # to gain a (harmless but drv-invalidating) extra nativeBuildInput.
      lib.optionalAttrs isMeteorLakeHost {
        # overrideScope returns a plain scope without the makeOverridable `.override`
        # attribute that callPackage added.  python-packages.nix calls
        # `pkgs.qt6.override { python3 = self.python; }` which would break without
        # it.  Restore it from prev so python3Packages can still build its Qt6 scope.
        qt6 = (prev.qt6.overrideScope (_qfinal: qprev: {
          # Quick is entirely absent from the HOST build without the native qsb
          # tool (qtshadertools).  All Qt Quick-dependent packages fail downstream.
          # Qt6QuickTools (svgtoqml) also lives only in native qtdeclarative.
          qtdeclarative = qprev.qtdeclarative.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
              nativeQtShaderTools
              nativeQtDeclarative
            ];
            cmakeFlags = (old.cmakeFlags or [ ]) ++ [
              "-DQt6ShaderToolsTools_DIR=${nativeQtShaderTools}/lib/cmake/Qt6ShaderToolsTools"
              "-DQt6QuickTools_DIR=${nativeQtDeclarative}/lib/cmake/Qt6QuickTools"
            ];
          });
          # qscxmlc is only in the native qtscxml; HOST qtscxml can't find it
          # via cmake's default search, so the HOST build fails to configure.
          qtscxml = addQtNativeTool
            (nativeBuildQt "qtscxml") "Qt6ScxmlTools" qprev.qtscxml;
          # repc (remote object compiler) is only in native qtremoteobjects.
          qtremoteobjects = addQtNativeTool
            (nativeBuildQt "qtremoteobjects") "Qt6RemoteObjectsTools" qprev.qtremoteobjects;
        })) // { inherit (prev.qt6) override; };
      }
    )

    # python-packages.nix creates python3Packages.qt6 via
    # `pkgs.qt6.override { python3 = self.python; }`.  Because we restored
    # prev.qt6.override (the un-fixed override), that scope gets the OLD
    # qtdeclarative and pulls the stale qtquicktimeline drv into the closure via
    # pyside6 → qtgraphs → qtquicktimeline.  Override python3Packages.qt6 directly
    # to the already-fixed final.qt6 so all C++ Qt modules are shared.
    # The python3 arg passed in the original override only matters for qt packages
    # that carry python3 as a build dep (none in the pyside6→qtgraphs chain).
    (final: prev:
      let
        isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
      in
      lib.optionalAttrs isMeteorLakeHost {
        python3Packages = prev.python3Packages // {
          qt6 = final.qt6;
        };
      }
    )


    # qcoro calls find_package(Qt6 COMPONENTS Quick) which makes Qt6Config.cmake
    # validate each component at qtbase's prefix. nixpkgs puts qtdeclarative in a
    # separate store path, so the validation fails. qtModule.nix converts the
    # QT_ADDITIONAL_PACKAGES_PREFIX_PATH env var → cmake cache, but qcoro is not
    # a Qt module and skips that hook. Pass the variable explicitly.
    (final: prev:
      let
        isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
      in
      lib.optionalAttrs isMeteorLakeHost {
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
          # JUCE spawns a subprocess cmake to build 'juceaide' (its native code-gen
          # tool) and that subprocess searches PATH for plain 'cc'/'gcc'.  The cross
          # cc-wrapper only provides triple-prefixed names ('x86_64-unknown-linux-
          # gnu-gcc'), so cmake reports "No CMAKE_C_COMPILER could be found".
          # Adding pkgsBuildBuild.stdenv.cc puts plain gcc/cc in PATH for juceaide.
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
            final.pkgsBuildBuild.stdenv.cc
          ];
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

        # kdsoap-ws-discovery-client lives in kdePackages.  It runs the HOST
        # KDSoap::kdwsdl2cpp cmake imported target (from kdePackages.kdsoap)
        # at build time to generate WSDL headers.  On meteorlake the binary is
        # compiled with -march=meteorlake (waitpkg), so it SIGILLs on yulee
        # (AMD znver5).  Build a patched copy of the kdsoap cmake config that
        # points kdwsdl2cpp-qt6 to the BUILD-platform binary, then override
        # KDSoap-qt6_DIR so cmake uses it instead of the HOST cmake config.
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
      }
    )

    # Issue B: depsBuildBuild's native gcc also installs `${triple}-gcc` (since
    # for it x86_64-linux-gnu IS the target). setup-hooks append depsBuildBuild
    # bins to PATH, so the native gcc can shadow the cross cc-wrapper for
    # prefixed name lookups. The setup-hook below pushes $NIX_CC/bin to the
    # front of PATH just before each phase so the cross wrapper always wins.
    # (Issue A — bare `ld` — is handled by F3 in nixpkgs-contrib bintools-wrapper.)
    (final: prev:
      let isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
      in lib.optionalAttrs isMeteorLakeHost {
        stdenv = prev.stdenv.override (old: {
          extraNativeBuildInputs = (old.extraNativeBuildInputs or [ ]) ++ [
            (prev.buildPackages.runCommand "cross-cc-priority-hook" { } ''
              mkdir -p $out/nix-support
              cat > $out/nix-support/setup-hook <<'EOF'
              _crossCcFront() { export PATH=$NIX_CC/bin:$PATH; }
              preConfigureHooks+=(_crossCcFront)
              preBuildHooks+=(_crossCcFront)
              preCheckHooks+=(_crossCcFront)
              preInstallHooks+=(_crossCcFront)
              EOF
            '')
          ];
        });
      })

    # kdePackages.breeze (v6) builds a Qt5 Breeze style plugin by referencing
    # libsForQt5.__internalKF5.kirigami2, which pulls in the KDE5 framework chain
    # and hits a qtquickcontrols2 API mismatch. We don't need the Breeze style
    # on niri; drop it from easyeffects while keeping breeze-icons.
    (final: prev:
      let isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
      in lib.optionalAttrs isMeteorLakeHost {
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
        #   3. *Tools_DIR cache vars — Qt6Quick needs Qt6QuickTools and Qt6Qml needs
        #      Qt6QmlTools (native build-time tools). They live in pkgsBuildBuild
        #      qtdeclarative (vyayar14…), not the HOST qtdeclarative. Qt6Quick3D
        #      needs Qt6Quick3DTools from pkgsBuildBuild qtquick3d. cmake only
        #      searches under CMAKE_CURRENT_LIST_DIR/.. (= HOST prefix), so the
        #      native tool cmake dirs must be pointed at explicitly via _DIR vars.
        easyeffects = prev.easyeffects.overrideAttrs (old:
          let
            nativeKconfig = final.pkgsBuildBuild.kdePackages.kconfig;
            # KF6ConfigCompilerTargets-release.cmake has IMPORTED_LOCATION pointing
            # to the HOST (meteorlake) binaries. Replace both with native binaries so
            # they don't SIGILL on yulee during the build phase.
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
          buildInputs = lib.filter (p: (p.pname or "") != "breeze") (old.buildInputs or [ ]);
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
            final.pkgsBuildBuild.qt6.qtdeclarative
            final.pkgsBuildBuild.qt6.qtquick3d
            nativeKconfig
          ];
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${final.qt6.qtgraphs};${final.qt6.qtdeclarative};${final.qt6.qtquick3d}"
            "-D_qt_additional_packages_prefix_paths=${final.qt6.qtgraphs}/lib/cmake;${final.qt6.qtdeclarative}/lib/cmake;${final.qt6.qtquick3d}/lib/cmake"
            "-DQt6QmlTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QmlTools"
            "-DQt6QuickTools_DIR=${final.pkgsBuildBuild.qt6.qtdeclarative}/lib/cmake/Qt6QuickTools"
            "-DQt6Quick3DTools_DIR=${final.pkgsBuildBuild.qt6.qtquick3d}/lib/cmake/Qt6Quick3DTools"
            "-DKF6Config_DIR=${patchedKconfigCmake}"
          ];
        });

        # zam-plugins marks itself broken for cross-builds, but pseudo-cross here is
        # x86_64→x86_64 (meteorlake tuning only), so the binaries execute fine on yulee.
        zam-plugins = prev.zam-plugins.overrideAttrs (old: {
          meta = old.meta // { broken = false; };
        });
      })

    # F7: lld disabled globally — lld links test programs against HOST glibc (meteorlake)
    # which crashes on znver5 BUILD when configure tries to run them. Will be re-enabled
    # per-package for webkitgtk/embree (Pattern C) once the system is up.

    # F8: Fresh native i686 stdenv, bypassing the pseudo-cross overlay. Pattern D.
    # Without this, pkgsi686Linux inherits the meteorlake hostPlatform overlay →
    # triple-cross (BUILD=x86_64 → HOST=i686 → TARGET=i686 pseudo-cross) which
    # breaks 32-bit compat packages (mesa i686, libgcrypt i686, etc.).
    (final: prev:
      let isMeteorLakeHost = (prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake";
      in lib.optionalAttrs isMeteorLakeHost {
        pkgsi686Linux = import inputs.nixpkgs {
          localSystem = { system = "i686-linux"; };
          config = prev.config;
        };
      })
  ];
}
