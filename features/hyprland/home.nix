{
  pkgs,
  lib,
  osConfig,
  ...
}:

let
  # hyprlang (Hyprland's config parser) uses bare $ for its own variable
  # substitution and chokes on embedded shell $(...) / $var syntax in exec
  # strings ("<name> expected near '$'"). Keep the shell logic in a real
  # script file instead of inlining it into hyprland.conf.
  hangulToggle = pkgs.writeShellScript "hangul-toggle" ''
    im=$(fcitx5-remote -n)
    if [ "$im" = hangul ]; then
      fcitx5-remote -s keyboard-us
      fcitx5-remote -c
    else
      fcitx5-remote -s hangul
      fcitx5-remote -o
    fi
  '';

  /*
    Rotation shim, hooks runner and the flocked iio-hyprland wrapper. Moved to
    ./rotation.nix so features/dms/plugins.nix can hand the SAME shim to the
    vehicle-motion-cues plugin: that plugin must own the accelerometer's IIO
    buffer for its motion cues, only one process can hold that buffer, and so
    it serves orientation from the same reader instead of competing with
    iio-hyprland for the sensor. Both emit the identical keyword batch, so the
    translation and every workaround live in one place still.
  */
  rotation = import ./rotation.nix {
    inherit pkgs lib;
    rotationHooks = osConfig.my.hyprland.rotationHooks;
  };
  inherit (rotation) runRotationHooks hyprctlTransformShim iioHyprlandWithTransformFix;

  /*
    Page-relative workspace navigation.

    Compositor-level on purpose, not part of any shell: the numbering is how
    the KEYS behave, and it stays coherent with no bar on screen at all. A
    shell that draws a workspace strip is expected to mirror this arithmetic
    (features/dms/plugins/workspaces does) rather than to own it.

    Slot N means "the Nth workspace of the group of ten I am currently in", not
    workspace N. The page is derived from the LIVE focused workspace on every
    press rather than tracked in a variable, so the bar plugin and the keybinds
    cannot disagree -- they run the same arithmetic against the same source and
    neither writes state the other has to trust.

    Legacy `hyprctl dispatch workspace N` does NOT work here: configType = "lua"
    routes dispatch through hl.dispatch(), and the bare form dies with
    "')' expected near '2'". The lua dispatcher form is the only one that
    parses.
  */
  wsSlot = pkgs.writeShellScript "hypr-ws-slot" ''
    slot="$1"
    active=$(${pkgs.hyprland}/bin/hyprctl activeworkspace -j | ${pkgs.jq}/bin/jq -r '.id')
    # Workspaces are 1-based, so bias before dividing: 1..10 -> page 0.
    page=$(( (active - 1) / 10 ))
    target=$(( page * 10 + slot ))
    if [ "$2" = move ]; then
      ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.window.move({ workspace = $target, follow = true })"
    else
      ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.focus({ workspace = $target })"
    fi
  '';

  /*
    Conserved column resize for the scrolling layout: move the seam between the
    focused column and its visible neighbour so one shrinks by exactly what the
    other grows -- like a tiling divider, which the scrolling layout otherwise
    is not. Argument is a signed fraction of the monitor width applied to the
    FOCUSED column (its neighbour gets the opposite).

    Why a script and not `colresize`. colresize only ever touches the focused
    column, and the freed/taken space is absorbed by the scroll offset (the
    neighbour keeps its width and the tape re-centres). Measured: shrinking one
    column left the other unchanged. The only primitive that resizes a SPECIFIC
    column is `hl.dsp.window.resize({ ..., window = "address:..." })`, so this
    resizes BOTH by address (+d and -d). With both outer edges pinned by their
    own resize the seam moves and nothing drifts (verified: A +150 / B -150 kept
    A's left and B's right edges, total constant).

    The seam is the focused column's right neighbour if it has one, else its
    left neighbour, among columns on the focused monitor's active workspace.
    Same primitive the screen-seam drag overlay uses. Floating focus is a no-op.
  */
  columnResizeSplit = pkgs.writeShellScript "hypr-column-resize-split" ''
    exec ${pkgs.python3.interpreter} ${./column-resize-split.py} "$1"
  '';


  /*
    Blank the panel WITHOUT suspending, and wake it on the next input.

    The two misc:*_enables_dpms options in ./hyprland.lua turn any keypress or pointer
    motion back into "monitors on" -- but the chord that runs this script is
    itself input. Its key releases (and the pointer nudge of letting go of the
    touchpad) land AFTER the dispatch, so with the options already armed the
    panel lights back up the instant it goes dark. Hence: disarm, blank, wait
    out the chord, re-arm. The window only has to outlast the release of keys
    you were already holding, so it is short; anything you press after it wakes
    the panel as intended.

    hl.config merges -- it is the same partial-table call DMS's colors.lua
    makes -- so restating just these two options leaves the rest of the config
    alone. Nothing here touches sleep: the machine stays fully awake, which is
    the point (lid close is the separate path, see features/dms/compositor.nix).
  */
  dpmsOff = pkgs.writeShellScript "hypr-dpms-off" ''
    armWake() {
      ${pkgs.hyprland}/bin/hyprctl eval \
        "hl.config({ misc = { key_press_enables_dpms = $1, mouse_move_enables_dpms = $1 } })" >/dev/null
    }
    armWake false
    ${pkgs.hyprland}/bin/hyprctl dispatch 'hl.dsp.dpms({ action = "off" })'
    ${pkgs.coreutils}/bin/sleep 1.5
    armWake true
  '';

in
lib.mkMerge [
{
  /*
    Screenshots. The region snip is now an IN-SHELL Quickshell overlay
    (features/dms/plugins/screen-snip), not slurp, because the S Pen cannot
    drive slurp:

      - slurp is a bare wlr client -- it binds only wl_pointer and wl_touch,
        never zwp_tablet_manager_v2 (slurp 1.5.0 carries no tablet symbols at
        all; the old "it has the symbols" note here was wrong).
      - Hyprland 0.56 routes a tablet tip ONLY through the tablet protocol
        (Tablets.cpp onTabletTip -> PROTO::tablet->down, no pointer-button
        emulation), so the pen warps the cursor over slurp but a tap/drag
        arrives as nothing. No slurp or Hyprland option bridges it. Touch
        (a finger) works because Hyprland emulates pointer for touch; the pen
        it does not.

    A Quickshell window is a qtwayland client: it binds the tablet protocol
    and Qt synthesizes a mouse press from the tip, so a MouseArea selection
    just works with the pen. Same idea as end-4/dots-hyprland's screenSnip.
    Print calls `dms ipc call screenSnip region` and falls back to hyprshot
    only when the shell is down; the DMS Screenshot bar widget calls the same
    IPC.

    CTRL+Print (output) and ALT+Print (window) stay on hyprshot -- they need
    no pen drag. NOTE from the grimblast->hyprshot switch that still holds:
    grimblast copy screen captured ALL monitors into one image; `-m output`
    captures the focused output only.
  */
  home.packages = lib.mkIf (osConfig.my.desktop.compositor == "hyprland") [
    pkgs.hyprshot
    # The DMS screen-snip overlay shells out to grim (magick and wl-copy are
    # already present); hyprshot wraps its own grim and does not expose it.
    pkgs.grim
    iioHyprlandWithTransformFix
    # iio-hyprland shells out to `hyprctl -j monitors | jq` internally; without
    # jq in PATH it fails immediately and aborts uncleanly (dbus_disconnect
    # crash) instead of just erroring on the missing monitor lookup.
  ];

  wayland.windowManager.hyprland = {
    enable = osConfig.my.desktop.compositor == "hyprland";

    # Lua, not hyprlang. Verified against this exact build's own source
    # (0.56.0's src/config/lua/bindings/*.cpp) rather than assumed from docs
    # of a fast-moving pre-1.0 API -- see the header of ./hyprland.lua.
    configType = "lua";
  };
}

  /*
    The config itself is ./hyprland.lua, a plain Lua file (lib/hypr-lua.nix);
    what it needs from Nix is handed over as `nix` below.

    mkBefore, and it is load-bearing. extraConfig is types.lines, so every
    feature's require("feat.<name>") line is concatenated into the one
    generated hyprland.lua -- that is what lets other features contribute
    binds and rules. Order between definitions is definition order, and
    flake.nix builds the feature list from `builtins.readDir ./features`,
    which is ALPHABETICAL: `dms` sorts before `hyprland`. Without an explicit
    order a contributed file runs before this one and calls hl.* before
    hl.config has run -- a Lua error at session start, not at build time.
    So: this one is mkBefore, every contributed one is mkAfter.
  */
  (lib.mkIf (osConfig.my.desktop.compositor == "hyprland") (import ../../lib/hypr-lua.nix { inherit lib; } {
    name = "hyprland";
    src = ./hyprland.lua;
    order = lib.mkBefore;
    values = {
      mod = osConfig.my.hyprland.modKey;
      primaryOutput = osConfig.my.desktop.primaryOutput;
      primaryOutputScale = toString osConfig.my.desktop.primaryOutputScale;
      autorotate = osConfig.my.desktop.autorotate;
      naturalScroll = !(osConfig.my.x-folding-trackpad.enable or false);
      hangulToggle = "${hangulToggle}";
      columnResizeSplit = "${columnResizeSplit}";
      wsSlot = "${wsSlot}";
      dpmsOff = "${dpmsOff}";
    };
  }))

  # Lua language server support: /.luarc.json in this repo reads ~/.config/hypr,
  # which holds the generated nix/*.lua modules, and these API stubs from the
  # running compositor's own package (the same ones Home Manager's
  # hypr/.luarc.json points at).
  (lib.mkIf (osConfig.my.desktop.compositor == "hyprland") {
    xdg.configFile."hypr/stubs".source = "${osConfig.programs.hyprland.package}/share/hypr/stubs";
  })
]
