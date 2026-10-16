{ inputs, pkgs, lib, osConfig, ... }:

let
  /*
    The same rotation shim features/hyprland/home.nix hands to iio-hyprland.

    vehicleMotionCues must own the accelerometer's IIO buffer to draw its
    motion cues, and only one process can hold that buffer -- so instead of
    losing a coin toss with iio-hyprland for the sensor, it serves orientation
    from the same reader and emits the identical
    `keyword monitor <out>,transform,N` batch at this shim. Every workaround
    the shim carries (keyword -> hl.* translation for the Lua parser, touch
    and tablet transforms, scrolling:direction, the reload needed to get back
    to transform 0, my.hyprland.rotationHooks) therefore still applies, and
    none of it is duplicated in QML.

    Imported rather than PATH-shadowed because the plugin runs it by absolute
    path from a Quickshell Process, not through a login shell.
  */
  rotation = import ../hyprland/rotation.nix {
    inherit pkgs lib;
    rotationHooks = osConfig.my.hyprland.rotationHooks;
  };


  /*
    The on-screen keyboard's key sender (plugins/osk-keyboard/vk/osk-vk.c): ~150
    lines of C on wayland-client + xkbcommon, the protocol header generated from
    the virtual-keyboard XML (vendored from wtype). wtype itself was the first
    choice and is NOT used: a new virtual keyboard per keystroke hung fcitx5.
  */
  oskVk = pkgs.stdenv.mkDerivation {
    pname = "osk-vk";
    version = "1";
    src = ./plugins/osk-keyboard/vk;
    nativeBuildInputs = [ pkgs.pkg-config pkgs.wayland-scanner ];
    buildInputs = [ pkgs.wayland pkgs.libxkbcommon ];
    buildPhase = ''
      runHook preBuild
      wayland-scanner client-header virtual-keyboard-unstable-v1.xml virtual-keyboard-unstable-v1-client-protocol.h
      wayland-scanner private-code virtual-keyboard-unstable-v1.xml virtual-keyboard-unstable-v1-protocol.c
      $CC -O2 -Wall -Wextra -o osk-vk -I. osk-vk.c virtual-keyboard-unstable-v1-protocol.c \
        $(pkg-config --cflags --libs wayland-client xkbcommon)
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 osk-vk $out/bin/osk-vk
      runHook postInstall
    '';
    meta.mainProgram = "osk-vk";
  };
in

lib.mkIf osConfig.my.dms.enable {
  # osk-vk: how the on-screen keyboard (oskKeyboard) types -- one persistent
  # Wayland virtual keyboard fed key presses on stdin. It replaced wvkbd
  # (2026-10-08: no S Pen input, no Super key); see plugins/osk-keyboard.
  home.packages = [ oskVk ];

  programs.dank-material-shell.plugins = {
    # The on-screen keyboard: a daemon plugin, one keyboard window, IPC target "osk".
    oskKeyboard = {
      enable = true;
      src = ./plugins/osk-keyboard;
    };
    # Its bar pill: show/hide and pin, driving the oskKeyboard instance.
    oskToggle = {
      enable = true;
      src = ./plugins/osk-toggle;
    };

    screenshot = {
      enable = true;
      src = ./plugins/screenshot;
    };

    # Replaces the stock workspaceSwitcher widget -- see settings.nix, where
    # "workspaceSwitcher" is dropped from leftWidgets in favour of this.
    pagedWorkspaces = {
      enable = true;
      src = ./plugins/workspaces;
    };

    noSleep = {
      enable = true;
      src = ./plugins/no-sleep;
    };

    # Unbinds the built-in keyboard's i8042 port so an external one can be used
    # alone. The UI only drives a system unit -- features/embedded-keyboard owns
    # the unit and the polkit rule, and explains why a Hyprland device rule
    # cannot do this while keyd holds every keyboard.
    embeddedKeyboard = {
      enable = true;
      src = ./plugins/embedded-keyboard;
    };

    # Windows-style switcher: the launcher's tile view (live previews) over
    # Hyprland's windows in most-recently-used order, previous window first
    # so Alt+Tab, Enter switches back. Derived from the
    # registry's dankHyprlandWindows, which sorts geometrically; do not
    # enable both, they share the "!" trigger. Bound to Alt+Tab in
    # compositor.nix.
    altTab = {
      enable = true;
      src = ./plugins/alt-tab;
    };

    # Region screenshot as an in-shell Quickshell overlay instead of a slurp
    # region, because slurp ignores tablet input and Hyprland routes the S Pen
    # tip only through the tablet protocol -- so the pen cannot drag a slurp
    # selection. A Quickshell (qtwayland) overlay gets Qt's tablet->mouse
    # synthesis, so the pen works. Bound to Print in features/hyprland (with
    # hyprshot as the shell-down fallback) and to the Screenshot bar widget.
    screenSnip = {
      enable = true;
      src = ./plugins/screen-snip;
    };

    # Drag the seam between two columns to resize both (conserved), with mouse,
    # finger, or S Pen -- an in-shell overlay because the pen cannot reach
    # Hyprland's native border resize (tablet tip is not a pointer button) and
    # the scrolling layout is not conserved on its own. Same primitive as
    # Super+;/' (features/hyprland/column-resize-split.py).
    columnSeamDrag = {
      enable = true;
      src = ./plugins/column-seam-drag;
    };

    /*
      Apple's Vehicle Motion Cues: dots at the screen edges shift against the
      vehicle's acceleration so a passenger's eyes see the motion their inner
      ear already feels.

      It also owns AUTOROTATION here, which is not scope creep but a
      consequence of the hardware: the cues need the accelerometer's IIO
      buffer, an IIO buffer has exactly one owner, and iio-sensor-proxy (which
      iio-hyprland listens to) takes it for orientation. Rather than have the
      two fight over the sensor, the plugin derives orientation from the
      gravity vector it already computes and fires the same keyword batch
      iio-hyprland would have -- see `rotation` above. So enabling this means
      NOT starting iio-hyprland, and rotationLock below has nothing left to
      kill; its job moves to `dms ipc call vehicleMotionCues toggleRotationLock`.

      Needs hosts/<host>/accelerometer.nix for IIO buffer access.

      Pinned from its own repo (features/dms/flake.nix) rather than vendored
      here, so it updates with `nix flake update vehicle-motion-cues` and can
      be used by anyone without this config.
    */
    vehicleMotionCues = {
      enable = true;
      # The patch seeds the plugin's idea of the current transform from the
      # compositor; features/hyprland restores the last orientation across
      # reloads and logins, so the screen can come up already rotated.
      src = pkgs.applyPatches {
        name = "vehicle-motion-cues";
        src = inputs.feat-dms.pluginSources.vehicleMotionCues;
        patches = [ ./vehicle-motion-cues-seed-transform.patch ];
      };
      settings = {
        # QML cannot read osConfig.* itself; ship it through
        # plugin_settings.json, same as rotationLock does.
        compositor = osConfig.my.desktop.compositor;
        monitor = osConfig.my.desktop.primaryOutput;
        manageRotation = osConfig.my.desktop.autorotate == "motion-cues";
        rotateCommand = rotation.transformHyprctl;
      };
    };

    /*
      Screenshot -> background Claude Code session -> reply over
      `dms ipc call claudeHelper replyFile`, shown in the bar popout, with
      switchable sessions. For maths and science it tutors: the first mistake
      and escalating hints, never the final answer. Placed in the bar by
      settings.nix.

      Runs `claude`, `grim`, `python3`, `latex`, `dvisvgm` and `magick` (with
      its rsvg delegate) from DMS's PATH. None is added here: they arrive via
      other features -- claude-code, latex, emacs/cursor-theme (imagemagick).
      Dropping one of those silently degrades this (no LaTeX images, or no
      session at all); declare them here if this is ever used without them.

      Pinned from its own repo like vehicleMotionCues; update with
      `nix flake update claude-helper` in features/dms.
    */
    claudeHelper = {
      enable = true;
      src = inputs.feat-dms.pluginSources.claudeHelper;
      # Markdown -> HTML for replies with LaTeX, so the formula images can be
      # sized and stay sharp at scale 1.5. By store path, same as
      # vehicleMotionCues' rotateCommand: no PATH entry for one plugin's tool.
      settings.cmarkCommand = "${pkgs.cmark-gfm}/bin/cmark-gfm";
    };

    /*
      Bar stopwatch. Click the timer icon to start; click the running time to
      pause; click while paused for a Resume / Reset popup. State lives in its
      daemon, so both bars (and every screen) show the same time and a
      rotation mid-run keeps it. Placed in the bar by settings.nix.

      Pinned from its own repo; update with `nix flake update stopwatch` in
      features/dms.
    */
    # Named barStopwatch, not stopwatch: dms-plugin-registry already defines
    # plugins.stopwatch (a different plugin) and the two `src`s collide.
    barStopwatch = {
      enable = true;
      src = inputs.feat-dms.pluginSources.stopwatch;
    };

    # Stays on for BOTH autorotate sources -- the lock is independent of
    # whether the motion cues are running. Under "iio" it kills and respawns
    # the listener as before; under "motion-cues" there is no listener to kill,
    # so it flips that plugin's own lock over IPC and the cues keep drawing
    # while rotation is held still.
    rotationLock = {
      enable = true;
      src = ./plugins/rotation-lock;
      # QML can't read osConfig.* itself -- ships both through
      # plugin_settings.json instead. The monitor is the same host-level
      # my.desktop.primaryOutput the niri/hyprland features use for the
      # autorotate listener this plugin kills and respawns.
      settings = {
        compositor = osConfig.my.desktop.compositor;
        monitor = osConfig.my.desktop.primaryOutput;
        source = osConfig.my.desktop.autorotate;
      };
    };
  };
  # altTab was staged live on 2026-09-20 as a hand-made symlink in the plugin
  # dir (pointing at the plugin's bare store path) so it could be tried
  # before a rebuild. home-manager refuses to clobber a link it did not
  # make, so that would fail the next switch. Drop it, but only while it
  # is still the foreign one -- a link into a home-manager-files tree is
  # ours and stays. Harmless once it has run; delete after the first switch.
  # Same one-time guard as altTab, for the live-staged screenSnip symlink.
  home.activation.screenSnipStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/screenSnip"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

  # Same one-time guard as altTab, for the claudeHelper symlink staged on
  # 2026-09-27 (pointing at the git checkout) to try it before a rebuild.
  home.activation.claudeHelperStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/claudeHelper"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

  # Same one-time guard as altTab, for the live-staged columnSeamDrag symlink.
  home.activation.columnSeamDragStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/columnSeamDrag"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

  # Same one-time guard again, for the live-staged vehicleMotionCues symlink
  # (pointed at the working tree while the plugin was being built and tested).
  home.activation.vehicleMotionCuesStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/vehicleMotionCues"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

  # Same one-time guard again, for the barStopwatch symlink staged on
  # 2026-10-06 (pointing at the git checkout) to try it before a rebuild.
  home.activation.barStopwatchStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/barStopwatch"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

  home.activation.altTabStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/altTab"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

}
