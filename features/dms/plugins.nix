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
    wvkbd upstream has no way to make the panel narrower than the full
    output width: the layer-shell anchor (BOTTOM | LEFT | RIGHT) is a
    compile-time constant with no CLI flag, so "not full width" is only
    reachable by patching. Also swaps the Compose key for Super on both
    default primary layers (portrait "Full" and landscape "Landscape" --
    wvkbd picks between them by aspect ratio, see the layout.mobintl.h edit
    below) -- Super otherwise only exists on the "Special" layer, reachable
    via the next-layer button, not on either primary typing layer.

    ANCHORED ON CODE, NOT ON LINE NUMBERS. This patch used to address every
    site by absolute line number, which broke the moment nixpkgs bumped
    wvkbd's source: main.c had grown fractional-scale support, so every
    target had moved 60-80 lines. The seds still "succeeded" -- they just
    landed on unrelated code. The insertion meant for the end of the
    `anchor` declaration landed in the MIDDLE of it, and the one meant for
    redimension_keyboard() overwrote a line of
    wp_fractional_scale_preferred_scale()'s parameter list, deleting that
    function. The result was a wall of confusing C errors ("expected '=',
    ',', ';' ... before '|' token") pointing at code nobody had touched on
    purpose.

    So: every main.c edit is now a substituteInPlace --replace-fail keyed on
    a unique line of surrounding code, which ABORTS THE BUILD if its anchor
    ever stops matching. A moved anchor now fails immediately, naming the
    text it could not find, instead of silently corrupting the translation
    unit. All four anchors were verified to match exactly once.

    Only the ANCHORS must match byte-for-byte; inserted text is free-form,
    so nix's ''...'' dedent (which strips a different amount of leading
    whitespace than main.c uses) cannot misalign it. That constraint is why
    the original avoided multi-line context matching, and it still holds --
    it just does not apply to the replacement side.

    layout.mobintl.h is the one place a plain context match genuinely is
    ambiguous: `{"Cmp", ...}` is byte-identical in NINE key arrays. Those two
    substitutions are therefore confined to their array's brace range, and
    the result is counted afterwards rather than assumed.
  */
  wvkbdFloating = pkgs.wvkbd.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # The panel-width state itself, declared after the `anchor` block ends
      # (anchored on its last line, the only ANCHOR_RIGHT in the file).
      substituteInPlace main.c \
        --replace-fail 'ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;' 'ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

/* 0 = fill horizontally; --width overrides */
static uint32_t surface_width = 0;'

      # -W/--width, spliced in ahead of the existing -L case.
      substituteInPlace main.c \
        --replace-fail '} else if (!strcmp(argv[i], "-L")) {' '} else if ((!strcmp(argv[i], "-W")) || (!strcmp(argv[i], "--width"))) {
            if (i >= argc - 1) {
                usage(argv[0]);
                exit(1);
            }
            surface_width = atoi(argv[++i]);
            if (surface_width > 0) {
                anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
            }
        } else if (!strcmp(argv[i], "-L")) {'

      # Request the narrower width from the compositor (upstream hardcodes 0,
      # meaning "fill the output").
      substituteInPlace main.c \
        --replace-fail 'zwlr_layer_surface_v1_set_size(layer_surface, 0, height);' \
                       'zwlr_layer_surface_v1_set_size(layer_surface, surface_width, height);'

      # redimension_keyboard() hardcodes keyboard.w to the full-output probe
      # width regardless of what was requested via set_size. The real layer
      # surface's configure event legitimately echoes back our requested
      # (narrower) width, so keyboard.w then never matches the compositor's
      # configure -- main.c's mismatch check (`keyboard.w != w`) treats that
      # as "not what we expected" and loops hide()/show() forever, never
      # reaching kbd_resize/drawing. Verified live: layer registers at the
      # right geometry but sits permanently inactive (hyprctl layers: `a: 0`),
      # nothing ever drawn.
      substituteInPlace main.c \
        --replace-fail '    keyboard.w = available_width;' \
                       '    keyboard.w = surface_width > 0 ? surface_width : available_width;'

      # The active layer set is chosen by aspect ratio, not by a fixed
      # default: `keyboard.landscape = available_width > available_height`.
      # Portrait (width < height) uses layers[] -> Full -> keys_full.
      # Landscape (width > height, our laptop's normal state) uses
      # landscape_layers[] -> Landscape -> keys_landscape -- a third,
      # separate array, NOT keys_full_wide (that one maps to the unused
      # FullWide id and isn't in either default cycle list). Missing this is
      # exactly why an earlier version of this patch only showed Super when
      # the panel was rotated vertical.
      sed -i '/^static struct key keys_full\[\] = {/,/^};/ s/^  {"Cmp", "Cmp", 1\.0, Compose, \.scheme = 1},$/  {"Sup", "Sup", 1.0, Mod, Super, .scheme = 1},/' layout.mobintl.h
      sed -i '/^static struct key keys_landscape\[\] = {/,/^};/ s/^  {"Cmp", "Cmp", 1\.0, Compose, \.scheme = 1},$/  {"Sup", "Sup", 1.0, Mod, Super, .scheme = 1},/' layout.mobintl.h

      # sed cannot fail on a non-match, so assert the outcome instead --
      # PER ARRAY, not as a file-wide count. Upstream already ships three
      # Super keys of its own (on the Special/landscape-special layers), so
      # a total-occurrence check conflates ours with theirs and reports a
      # bogus failure. What actually has to hold is local to each array:
      # the Compose key is gone and exactly one Super key took its place.
      for _arr in keys_full keys_landscape; do
        _block=$(sed -n "/^static struct key $_arr\[\] = {/,/^};/p" layout.mobintl.h)
        _sup=$(printf '%s\n' "$_block" | grep -cF '{"Sup", "Sup", 1.0, Mod, Super, .scheme = 1},') || true
        _cmp=$(printf '%s\n' "$_block" | grep -cF '{"Cmp", "Cmp", 1.0, Compose, .scheme = 1},') || true
        if [ -z "$_block" ]; then
          echo "wvkbd patch: array $_arr[] not found in layout.mobintl.h" >&2
          exit 1
        fi
        if [ "$_sup" != 1 ] || [ "$_cmp" != 0 ]; then
          echo "wvkbd patch: $_arr[] has $_sup Super / $_cmp Compose keys, expected 1 / 0" >&2
          echo "  (the array moved, or the Compose entry changed shape upstream)" >&2
          exit 1
        fi
      done
    '';
  });
in

lib.mkIf osConfig.my.dms.enable {
  # wvkbd: the only runtime dependency oskToggle spawns/kills.
  home.packages = [ wvkbdFloating ];

  programs.dank-material-shell.plugins = {
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
      `dms ipc call claudeHelper replyFile`, shown in its own window (floated
      by compositor.nix). For maths and science it tutors: the first mistake
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

  home.activation.altTabStagedLink = lib.hm.dag.entryBefore [ "checkLinkTargets" ] ''
    l="$HOME/.config/DankMaterialShell/plugins/altTab"
    if [ -L "$l" ] && ! readlink "$l" | grep -q -- '-home-manager-files/'; then
      run rm -f "$l"
    fi
  '';

}
