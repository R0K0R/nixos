/*
  TEMPORARY DUCT TAPE. Delete this file once the real fix lands in the fork.

  THE BUG
  -------
  pkgs/build-support/setup-hooks/cmake-intra-isa-cross.sh provides a mechanism
  ("addCMakeCrossHelperFlags") letting a package drop cmake flags into
  nix-support/cmake-cross-helper-flags and have consumers forward them
  automatically. The qt6 modules use it to hand consumers the location of the
  BUILD-platform *Tools_DIR cmake packages -- qmlcachegen, qmltyperegistrar and
  friends, which a cross-built Qt deliberately does not install:

      $ cat <qtdeclarative-dev>/nix-support/cmake-cross-helper-flags
      -DQt6QmlTools_DIR=<buildPlatform qtdeclarative>/lib/cmake/Qt6QmlTools
      -DQt6QuickTools_DIR=<buildPlatform qtdeclarative>/lib/cmake/Qt6QuickTools

  The two halves of that patch disagree about which dependency list to look in.
  qtModule.nix's own comment says "consumers with this module in buildInputs",
  but the hook registers itself as:

      addEnvHooks "$hostOffset" addCMakeCrossHelperFlags

  The hook is injected through the cross stdenv's extraNativeBuildInputs, so
  within it hostOffset is -1. setup.sh:665 maps that to pkgHookVarVars[0] ==
  pkgBuildHookVars == (envBuildBuildHook, envBuildHostHook, envBuildTargetHook)
  -- the three BUILD-platform accumulators. buildInputs live in pkgsHostTarget,
  reachable only from offset 0. So the hook can never see the packages that
  publish the file, and the mechanism is dead for all six publishers (qtbase,
  qtdeclarative, qtshadertools, qtscxml, qtremoteobjects, qtquick3d).

  It went unnoticed because the intra-ISA strictDeps relaxation forced
  _addToEnv down its non-strict branch, which runs every hook over all six
  accumulators and so ignores offsets entirely. Dropping that relaxation
  exposed it, as (in hyprland-qt-support):

      -- Could NOT find Qt6QmlTools (missing: Qt6QmlTools_DIR)
      Qt6Qml could not be found because dependency Qt6QmlTools could not be found.

  Confirmed by diffing the last successful build's log against the failing one:
  the working `cmake flags:` line carried -DQt6QmlTools_DIR, -DQt6QuickTools_DIR
  and -DQt6ShaderToolsTools_DIR; the failing one carries none, while the two
  derivations are otherwise identical modulo input hashes.

  THE REAL FIX, AND WHY IT IS NOT DONE HERE
  -----------------------------------------
  One line in that hook -- also register at "$targetOffset", which maps to
  pkgHostHookVars and so iterates pkgsHostTarget. But the hook is referenced by
  19 stdenv outputs, so touching it rehashes every derivation in the
  pseudo-cross store. Deferred deliberately; this file buys time.

  THE DUCT TAPE
  -------------
  Hang the same flags off qt6.wrapQtAppsHook instead. That hook is a
  nativeBuildInput of essentially every Qt consumer, and nativeBuildInputs land
  in pkgsBuildHost -- one of the three accumulators the existing hostOffset
  registration already scans. The flags therefore arrive through the
  *unmodified* mechanism, and stdenv is never touched.

  Appended to buildCommand, not postInstall: makeSetupHook builds via
  runCommand, and genericBuild (setup.sh:1806) evals buildCommand and returns
  before definePhases, so postInstall would be silently ignored.

  Scope: qt6-packages.nix:23 takes `qt6 = pkgsHostTarget.qt6` and spreads it,
  and pkgs/kde/default.nix builds its scope from qt6Packages, so overriding qt6
  here reaches qt6Packages and kdePackages too.

  No cycle: qtModule.nix does not use wrapQtAppsHook, so pointing the hook at
  pkgsBuildBuild.qt6.* does not feed back into the modules. The
  hostPlatform != buildPlatform guard additionally keeps the override out of
  the buildPlatform package set, where it would otherwise recurse into itself.

  All seven referenced buildPlatform module outputs were already in the store
  when this was written, so this drags in no new Qt builds.

  Consumers that use none of these get unused -D flags, which cmake reports as
  a warning at most.
*/
final: prev:

let
  # Both taken from `prev`, not `final`. Which attribute NAMES an overlay
  # defines may not depend on `final`: resolving that requires the final set,
  # which is being defined by this very overlay. Hence `qt6` is defined
  # unconditionally below and only its VALUE is conditional -- values are lazy,
  # names are not.
  inherit (prev) lib;

  # Keyed on targetPlatform, not hostPlatform. wrapQtAppsHook is a
  # nativeBuildInput, so consumers get it spliced out of pkgsBuildHost -- and
  # in that set hostPlatform == buildPlatform (it runs on the builder), so a
  # hostPlatform test switches the override off in exactly the set that needs
  # it. targetPlatform is what distinguishes it: pkgsBuildHost targets the
  # cross platform, while pkgsBuildBuild has all three equal, which is what
  # keeps `bb` below from recursing into an overridden set.
  isCross =
    prev.stdenv.targetPlatform != prev.stdenv.buildPlatform
    || prev.stdenv.hostPlatform != prev.stdenv.buildPlatform;

  bb = final.pkgsBuildBuild.qt6;

  crossHelperFlags = [
    "-DQt6CoreTools_DIR=${bb.qtbase}/lib/cmake/Qt6CoreTools"
    "-DQt6QmlTools_DIR=${bb.qtdeclarative}/lib/cmake/Qt6QmlTools"
    "-DQt6QuickTools_DIR=${bb.qtdeclarative}/lib/cmake/Qt6QuickTools"
    "-DQt6ShaderToolsTools_DIR=${bb.qtshadertools}/lib/cmake/Qt6ShaderToolsTools"
    "-DQt6ScxmlTools_DIR=${bb.qtscxml}/lib/cmake/Qt6ScxmlTools"
    "-DQt6RemoteObjectsTools_DIR=${bb.qtremoteobjects}/lib/cmake/Qt6RemoteObjectsTools"
    "-DQt6Quick3DTools_DIR=${bb.qtquick3d}/lib/cmake/Qt6Quick3DTools"
  ];
in
{
  qt6 =
    if !isCross then
      prev.qt6
    else
      # overrideScope returns a plain scope, dropping the makeOverridable
      # `.override` that callPackage added. Restore it from prev, exactly as the
      # qt6 overlay in hosts/galaxybook4-pro360/default.nix does -- that one runs
      # later and reads `prev.qt6.override`, i.e. this scope, and
      # python-packages.nix calls `pkgs.qt6.override { python3 = ...; }`.
      (prev.qt6.overrideScope (
        _qtFinal: qtPrev: {
          wrapQtAppsHook = qtPrev.wrapQtAppsHook.overrideAttrs (old: {
            buildCommand =
              (old.buildCommand or "")
              + ''
                mkdir -p "$out/nix-support"
                printf '%s\n' ${lib.escapeShellArgs crossHelperFlags} \
                  > "$out/nix-support/cmake-cross-helper-flags"
              '';
          });
        }
      ))
      // {
        inherit (prev.qt6) override;
      };
}
