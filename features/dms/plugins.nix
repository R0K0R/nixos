{ pkgs, lib, osConfig, ... }:

let
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

    noSleep = {
      enable = true;
      src = ./plugins/no-sleep;
    };

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
      };
    };
  };
}
