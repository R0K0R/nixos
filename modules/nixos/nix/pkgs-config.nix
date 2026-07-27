{ inputs, pkgs, lib, ... }:

let
  # Same nixpkgs pin, but without host gcc.arch — so nix substitutes from cache.nixos.org.
  genericPkgs = import inputs.nixpkgs {
    system = pkgs.stdenv.hostPlatform.system;
  };

  qtbaseFix = old: {
    # qfloat16_f16c.c + stub defs both compile when -DQFLOAT16_INCLUDE_FAST is set on meteorlake.
    postPatch =
      (old.postPatch or "")
      + ''
        sed -i 's/^#ifdef QFLOAT16_INCLUDE_FAST$/#if 0 \/\* nix: F16C redefinition \*\//' \
          src/corelib/global/qfloat16.cpp
      '';
    preBuild =
      (old.preBuild or "")
      + ''
        find . -type f -name Makefile -print0 \
          | xargs -0 sed -i 's/[[:space:]]*-DQFLOAT16_INCLUDE_FAST//g' 2>/dev/null || true
      '';
  };

  # overrideScope only replaces listed attrs; other Qt modules keep the old qtbase/qmake drvs baked in.
  rebindQtbase =
    qtbase: qmake: super:
    let
      isQtModule = name: pkg:
        name == "wrapQtAppsHook" || name == "qttools" || name == "qttranslations"
        || (lib.isDerivation pkg && lib.hasPrefix "qt" (pkg.pname or name));
      skipQtbaseOverride = name: builtins.elem name [ "qtquickcontrols" "qttranslations" ];
      hasQmakeHook =
        drv:
        lib.any (x: x != null && lib.getName x == "qmake-hook") (drv.nativeBuildInputs or [ ]);
    in
    lib.mapAttrs (
      name: pkg:
      if name == "qtbase" then
        qtbase
      else if name == "qmake" then
        qmake
      else if isQtModule name pkg && lib.isDerivation pkg && pkg ? override then
        let
          withQtbase =
            if skipQtbaseOverride name then
              pkg
            else
              let attempt = lib.tryEval (pkg.override { inherit qtbase; }); in
              if attempt.success then attempt.value else pkg;
          pkg' = withQtbase;
        in
        if !(pkg' ? overrideAttrs) || !(hasQmakeHook pkg') then
          pkg'
        else
          pkg'.overrideAttrs (old: {
            nativeBuildInputs =
              lib.filter (input: input != null && lib.getName input != "qmake-hook") (
                old.nativeBuildInputs or [ ]
              )
              ++ [ qmake ];
          })
      else
        pkg
    ) super;
in
{
  nixpkgs.config.allowUnfree = true;

  # Transitive eval of python2/pypy stack; blocked by CVE-2025-47273 in current nixpkgs.
  nixpkgs.config.permittedInsecurePackages = [
    "pypy2.7-setuptools-44.0.0"
    "pypy2.7-pip-20.3.4"
  ];

  # emacs-pgtk 30.x is flagged broken upstream but the override in
  # modules/home/r0k0r/editors/emacs/env.nix patches around it. Downgrade to a warning.
  nixpkgs.config.problems.handlers.emacs-pgtk.broken = "warn";
  nixpkgs.config.problems.handlers.zoom.broken = "warn";

  nix.package = genericPkgs.nix;

  nixpkgs.overlays = lib.mkAfter [
    (final: prev:
      let
        # Single source of truth for tests we can't run in the yulee sandbox.
        # Each entry: package attribute → reason. Tests are killed via overrideAttrs
        # so installCheck (which doesn't honour `nixpkgs.config.doCheckByDefault`)
        # also stops. perl5Packages handled separately below (nested attrset).
        testsKilled = {
          # source-level / -march=meteorlake
          assimp = "C vs C++ float-compare drift under -march=meteorlake";
          # OOM under parallel build
          libhwy = "~200 parallel C++ test targets OOM cc1plus on the builder";
          # headless sandbox missing devices / IPC / fs features
          upower = "test_wacom_dongle SIGABRTs (needs uevent/netlink)";
          rsync = "hardlinks test forbidden across sandbox fs boundaries";
          xdg-desktop-portal = "portal tests need a session DBus";
          xdg-desktop-portal-gnome = "portal tests need a session DBus";
          openssl = "70-test_quic_multistream.t timing-flaky in deterministic sandbox";
          # pseudo-cross: ispc's test runner invokes clang.cc (raw, no cc-wrapper env);
          # linker can't find Scrt1.o/crti.o/-lstdc++ without LIBRARY_PATH, and
          # gnu/stubs-32.h is missing on pure 64-bit glibc-dev. ispc binary itself builds fine.
          ispc = "test runner uses raw clang.cc lacking LIBRARY_PATH in pseudo-cross";
        };
        killCheck = pkg: pkg.overrideAttrs (_: { doCheck = false; doInstallCheck = false; });
        killedDrvs = lib.mapAttrs (n: _: killCheck prev.${n}) testsKilled;

        # musl, glibc, and libgcc all use stdenvNoLibc whose bintools-wrapper only ships
        # the prefixed ld (x86_64-unknown-linux-gnu-ld), not bare `ld`. In pseudo-cross
        # the build and target triples share the same config string, so collect2 treats
        # the link as native and calls bare `ld` — which doesn't exist in that wrapper.
        #
        # Two levers:
        #   COLLECT_LDP — read by collect2 before PATH/--with-ld; covers C-compiled pkgs.
        #   preConfigure PATH symlink — for build systems that call `ld` directly
        #                              (glibc's Makefiles bypass collect2 entirely).
        nolibcLD = "${prev.stdenvNoLibc.cc.bintools}/bin/${prev.stdenvNoLibc.hostPlatform.config}-ld";
        fixNoLibcLD = pkg: pkg.overrideAttrs (old: {
          env = (old.env or { }) // { COLLECT_LDP = nolibcLD; };
          preConfigure = (old.preConfigure or "") + ''
            mkdir -p "$TMPDIR/_ldwrap"
            ln -sf "${nolibcLD}" "$TMPDIR/_ldwrap/ld" || true
            export PATH="$TMPDIR/_ldwrap:$PATH"
          '';
        });
      in
      killedDrvs // {
        # ---- nixos-rebuild cache redirect ----
        # On the critical path of every switch and march-agnostic (Python interpreter).
        # `genericPkgs` is the same pin without `gcc.arch`, so output drvs substitute from cache.nixos.org.
        nixos-rebuild = genericPkgs.nixos-rebuild;
        nixos-rebuild-ng = genericPkgs.nixos-rebuild-ng;  # 26.05 Python rewrite of the same tool

        # ---- Per-package overrides not covered by the testsKilled map ----

        # guile 3.0.11 already incorporates the cross-compilation patch that nixpkgs
        # applies conditionally when hostPlatform != buildPlatform. In pseudo-cross
        # that condition fires but the patch is already in the tarball → "already applied".
        # patchFlags --forward silently skips already-applied patches.
        # guile 3.0.11 already incorporates the cross-compilation patch
        # (c117f8edc471d3362043d88959d73c6a37e7e1e9) that nixpkgs conditionally applies
        # when hostPlatform != buildPlatform. In pseudo-cross that condition fires but
        # the patch is already in the tarball → "already applied" failure.
        # Filter it out by its commit hash in the store path name.
        guile = prev.guile.overrideAttrs (old: {
          patches = lib.filter (p:
            !(lib.hasSuffix "c117f8edc471d3362043d88959d73c6a37e7e1e9"
                (builtins.baseNameOf (toString p)))
          ) (old.patches or [ ]);
        });

        # wcslib postInstall does `rm $out/share/doc/wcslib/wcslib` to clean up a
        # self-referential symlink the Makefile creates in native builds. In pseudo-cross
        # the Makefile creates a proper wcslib -> wcslib-<platform> symlink instead,
        # so the nested path never exists and bare rm fails. Use rm -f.
        wcslib = prev.wcslib.overrideAttrs (_: {
          postInstall = "rm -f $out/share/doc/wcslib/wcslib";
        });

        # cursor-cli ships prebuilt binaries; auto-patchelf needs libgcc_s and libstdc++
        # explicitly in scope to patch their RPATHs.
        cursor-cli = prev.cursor-cli.overrideAttrs (old: {
          buildInputs = (old.buildInputs or [ ]) ++ [
            prev.stdenv.cc.cc.lib
          ];
        });

        perl5Packages = prev.perl5Packages // {
          Test2Harness = prev.perl5Packages.Test2Harness.overrideAttrs (_: { doCheck = false; doInstallCheck = false; });
          WWWRobotRules = prev.perl5Packages.WWWRobotRules.overrideAttrs (_: { doCheck = false; doInstallCheck = false; });
          # MIME-Charset bundles Module::Install in inc/ which requires Fcntl (dynamic
          # loading). In pseudo-cross the build uses a static perl without dynamic loading.
          # Removing inc forces use of system ExtUtils::MakeMaker instead.
          MIMECharset = prev.perl5Packages.MIMECharset.overrideAttrs (old: {
            postPatch = (old.postPatch or "") + "rm -rf inc";
          });
        };

        # NOTE: musl/glibc/libgcc fixNoLibcLD workarounds removed — testing upstream
        # bintools-wrapper fix (bare-ld symlink for pseudo-cross) via --override-input.

        # (The gfortran/gccgo pseudo-cross --disable-bootstrap overrides that
        # used to live here were removed -- fixed at the root in the fork's
        # gcc/common/configure-flags.nix, where disableBootstrap' now honours
        # --disable-bootstrap for langFortran/langGo when
        # hostPlatform.config == targetPlatform.config. Candidate upstream PR.)

      # snobol4's hand-rolled configure only accepts --prefix/--bindir/--mandir/--snolibdir/
      # --with-tcl/--with(out)-docs. Cross stdenv injects --sbindir/--includedir/--libdir/
      # --build/--host and configure bails on the first unknown flag.
      snobol4 = prev.snobol4.overrideAttrs (old: {
        outputs = [ "out" ];
        setOutputFlags = false;
        configurePlatforms = [ ];
        configureFlags = [
          "--prefix=${placeholder "out"}"
          "--bindir=${placeholder "out"}/bin"
          "--mandir=${placeholder "out"}/share/man"
          "--snolibdir=${placeholder "out"}/lib/snobol4"
          "--without-docs"
        ];
        # `make install` uses INSTALL_BIN_FLAGS=-s which invokes bare `strip`.
        # In pseudo-cross only the prefixed strip exists; clear the flag so
        # coreutils install doesn't call strip. stdenv strips after install.
        preInstall = (old.preInstall or "") + ''
          sed -i 's/^INSTALL_BIN_FLAGS=.*/INSTALL_BIN_FLAGS=/' Makefile2
        '';
      });

      # GCC + meteorlake: -Wmaybe-uninitialized fails some packages (e.g. libclang); nixpkgs only waives cross builds.
      stdenv = prev.stdenv.override {
        preHook =
          (prev.stdenv.preHook or "")
          # -Wmaybe-uninitialized is GCC-only. Gate on the compiler rather than
          # eval-time prev.stdenv.cc.isGNU: the latter is always true (base
          # stdenv is GCC) and bakes the flag into the preHook string, which the
          # clang stdenvs that `overrideCC` produces (libc++, compiler-rt, ...)
          # inherit verbatim -- clang then warns "unknown warning option", which
          # matches CMake's FAIL_REGEX "unknown .*option"
          # (CMakeCheckCompilerFlagCommonPatterns.cmake) and fails *every*
          # check_compiler_flag despite exit 0, including
          # CXX_SUPPORTS_NOSTDINCXX_FLAG -- so libc++ drops -nostdinc++ and
          # gcc's libstdc++ headers leak into the libc++ build.
          #
          # The test must use only bash builtins on variables set *earlier in
          # this same file*: preHook is spliced into the top of setup.sh, which
          # runs long before PATH is populated (`PATH=` is ~line 626,
          # `runHook preHook` ~line 652). A `"$CC" --version | grep` test there
          # finds neither $CC (a bare name) nor grep, exits 127, and `!` turns
          # that into an unconditional export -- the exact leak this guards.
          # $defaultNativeBuildInputs is set a few lines above and ends in the
          # cc-wrapper (...-gcc-wrapper-15.3.0 vs ...-clang-wrapper-21.1.8).
          #
          # Platform guard: only the meteorlake HOST stdenv gets this. Overlays
          # apply to *every* splice, so without the guard this string also lands
          # in pkgsBuildHost's stdenv -- the BUILD platform, which has no gcc.arch
          # and never hits -Wmaybe-uninitialized from -march. That made every
          # build-platform derivation differ from upstream and lose
          # cache.nixos.org substitutability; measured, build-platform is ~91% of
          # the toplevel closure (17444 of 19045 drvs), so the whole cache win
          # hinges on this one predicate. Same guard the LIBRARY_PATH/CPATH block
          # below already uses.
          + lib.optionalString ((prev.stdenv.hostPlatform.gcc or { }).arch or "" == "meteorlake") ''
            case "''${defaultNativeBuildInputs:-}" in
              *-clang-wrapper-*) ;;
              *)
                export NIX_CFLAGS_COMPILE="''${NIX_CFLAGS_COMPILE:-} -Wno-error=maybe-uninitialized"
                export NIX_CXXFLAGS_COMPILE="''${NIX_CXXFLAGS_COMPILE:-} -Wno-error=maybe-uninitialized"
                ;;
            esac
          ''
          # Pseudo-cross root fix: raw cross gcc invocations (Go's bootstrap, GCC's
          # internal stage2-bubble, anything that bypasses the nixpkgs cc-wrapper) lack
          # the wrapper's runtime -B/-L for glibc startfiles and libgcc_s. LIBRARY_PATH
          # and CPATH are honoured by gcc itself (raw or wrapped), so exporting them
          # eliminates the whole class of "raw gcc can't find glibc" failures —
          # replaces the per-package whack-a-mole that came before.
          #
          # Guard: bootstrap stages have generic x86_64 hostPlatform (no gcc.arch).
          # Adding glibc to LIBRARY_PATH during bootstrap would point at a not-yet-built
          # glibc store path. Only fires on the final cross-stdenv.
          + lib.optionalString ((prev.stdenv.hostPlatform.gcc or {}).arch or "" == "meteorlake") ''
            export LIBRARY_PATH="${final.stdenv.cc.libc}/lib:${lib.getLib final.stdenv.cc.cc}/lib''${LIBRARY_PATH:+:}''${LIBRARY_PATH:-}"
            export CPATH="${final.stdenv.cc.libc_dev}/include''${CPATH:+:}''${CPATH:-}"
          '';
      };

      # Drop qttranslations from qtbase (bootstrapScope does the same) and rebind all Qt modules.
      libsForQt5 = prev.libsForQt5.overrideScope (_self: super:
        let
          qtbase =
            (super.qtbase.override {
              qttranslations = null;
            }).overrideAttrs qtbaseFix;
          qmake = super.qmake.override { inherit qtbase; };
          rebound = rebindQtbase qtbase qmake super;
          qtsvg = rebound.qtsvg.override { inherit qtbase; };
          qtdeclarative = rebound.qtdeclarative.override { inherit qtbase qtsvg; };
          qtquickcontrols = rebound.qtquickcontrols.override { inherit qtdeclarative; };
          qtwebchannel = rebound.qtwebchannel.override { inherit qtbase qtdeclarative; };
          qtwayland = rebound.qtwayland.override {
            inherit qtbase qtquickcontrols;
          };
          wrapQtAppsHook = rebound.wrapQtAppsHook.override {
            inherit qtwayland;
          };
        in
        rebound
        // {
          inherit qtdeclarative qtquickcontrols qtwebchannel qtwayland wrapQtAppsHook qtsvg;
          qt5 =
            rebound.qt5
            // {
              inherit qtbase qmake qtdeclarative qtquickcontrols qtwebchannel qtwayland wrapQtAppsHook qtsvg;
              qttools = rebound.qttools;
            };
        });
      })
  ];
}
