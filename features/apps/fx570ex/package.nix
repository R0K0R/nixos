/*
  fx-570EX -- a Casio ClassWiz-style scientific calculator, Qt 6 Widgets.

  WRITTEN HERE, NOT FETCHED. The source is vendored under src/ and tests/
  rather than pulled from a remote, because there is no upstream: this is a
  from-scratch implementation and the feature directory is its only home. That
  keeps the `rm -r features/fx570ex` property the root flake describes -- the
  app and its packaging leave together -- at the cost of the source living in a
  config repo. The development checkout at ~/git_shit/scientific_calculator_qt
  is a scratch copy; when it moves ahead, re-vendor with

    cp -r ~/git_shit/scientific_calculator_qt/{src,tests,CMakeLists.txt} \
          features/fx570ex/

  NOT A ROM EMULATOR. The accurate way to get an fx-570EX is to run its real
  firmware under an nX-U8/100 emulator (CasioEmuX, user202729/CasioEmu), and
  that was rejected deliberately: both are GPL-3.0 and, more to the point, both
  need a ROM dumped off physical hardware that nobody may redistribute. This
  reimplements the behaviour from the published manual instead, so it builds
  from source with no blobs and no licence entanglement.
*/
{
  lib,
  stdenv,
  cmake,
  ninja,
  qt6,
  makeDesktopItem,
  copyDesktopItems,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "fx570ex";
  version = "1.0.0";

  /*
    Only the things that actually compile. `src = ./.` would put nixos.nix,
    package.nix and icon.svg in the store path, so editing a module comment
    would change the source hash and rebuild the whole app for nothing.
    fileset also keeps a stray build/ directory in the working tree from
    leaking into the derivation.
  */
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./CMakeLists.txt
      ./src
      ./tests
    ];
  };

  nativeBuildInputs = [
    cmake
    ninja
    # Installs `desktopItems` below into $out/share/applications during
    # postInstall's hook slot, which is why the explicit postInstall here only
    # has to handle the icon.
    copyDesktopItems
    # Puts the platform plugins and QML paths into the binary's wrapper.
    # Without it the app aborts at startup with "could not find or load the Qt
    # platform plugin xcb/wayland" -- nothing in the store path tells Qt where
    # its own plugins are.
    qt6.wrapQtAppsHook
  ];

  buildInputs = [ qt6.qtbase ];

  /*
    The self-test drives the same Engine the keypad does -- 41 checks over
    operator precedence, the exact-form arithmetic, trigonometry and the error
    taxonomy. It links QtCore alone and never opens a window, so a display is
    not what stands in its way.

    GATED ON canExecute, AND IN THIS TREE THAT IS FALSE. build and host share
    the config triple here and differ only by `gcc.arch = "meteorlake"`, which
    still counts as cross, and nixpkgs will not promise the builder can run a
    host binary. It is right not to: this derivation gets farmed out to
    ssh-ng://yulee, and a -march=meteorlake test binary on an older builder
    SIGILLs rather than failing a check. Writing a plain `doCheck = true` looks
    like it runs the tests and does not -- stdenv drops it silently -- so the
    condition is spelled out instead.

    Where it DOES run: any native build. `nix-shell && ctest --test-dir build`
    in the working tree, or this package on a host with my.tuning.enable =
    false, which gets untuned upstream nixpkgs. Worth keeping wired up for
    those, because Exact.cpp is the part most likely to break silently under a
    different compiler or optimisation level -- a wrong answer looks exactly
    like a right one until something checks it.
  */
  doCheck = stdenv.buildPlatform.canExecute stdenv.hostPlatform;

  # No point compiling the test binary in the configurations that cannot run it.
  cmakeFlags = [ (lib.cmakeBool "BUILD_TESTING" finalAttrs.doCheck) ];

  checkPhase = ''
    runHook preCheck
    ./fx570ex_selftest
    runHook postCheck
  '';

  desktopItems = [
    (makeDesktopItem {
      name = "fx570ex";
      desktopName = "fx-570EX Calculator";
      comment = "Casio ClassWiz style scientific calculator";
      exec = "fx570ex";
      icon = "fx570ex";
      terminal = false;
      categories = [ "Utility" "Calculator" "Science" ];
      keywords = [ "calculator" "scientific" "casio" "classwiz" "maths" ];
      startupWMClass = "fx570ex";
    })
  ];

  postInstall = ''
    install -Dm644 ${./icon.svg} $out/share/icons/hicolor/scalable/apps/fx570ex.svg
  '';

  meta = {
    description = "Casio fx-570EX (ClassWiz) style scientific calculator";
    longDescription = ''
      Natural textbook entry -- stacked fractions, lifted exponents, drawn
      radicals -- over an engine that keeps an exact (p + q*sqrt(r))/s form
      beside every double, so sqrt(8) answers 2*sqrt(2) and cos(30) answers
      sqrt(3)/2, with S<=>D toggling to the decimal. Follows the ClassWiz
      calculation-priority table, which is why 6/2(1+2) is 9 while 1/2pi is
      0.159..., and reproduces the physical keypad layout.
    '';
    # No licence attribute on purpose: this is first-party code with no licence
    # chosen yet, and asserting one here would be inventing a fact.
    platforms = lib.platforms.linux;
    mainProgram = "fx570ex";
  };
})
