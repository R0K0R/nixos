{ pkgs, osConfig, ... }:

let
  /*
    wvkbd upstream has no way to make the panel narrower than the full
    output width: the layer-shell anchor (BOTTOM | LEFT | RIGHT) is a
    compile-time constant with no CLI flag, so "not full width" is only
    reachable by patching. Also swaps the main "Full" layer's Compose key
    for Super -- Super otherwise only exists on the "Special" layer,
    reachable via the next-layer button, not on the primary typing layer.

    Both edits are pinned to exact upstream line numbers rather than
    context blocks: the surrounding code (esp. the Compose key line) is
    byte-identical across several other layers in the same file, so a
    context-matched substitution would silently touch the wrong layer.
    Fine for a single pinned nixpkgs revision; will need re-checking if
    wvkbd is ever bumped.
  */
  wvkbdFloating = pkgs.wvkbd.overrideAttrs (old: {
    # Line-number-targeted sed, not substituteInPlace: nix's ''...''
    # dedent strips leading whitespace by a different amount than main.c's
    # own indentation, so a whitespace-sensitive multi-line context match
    # silently fails to find its anchor. Insertions sidestep that (the
    # inserted text's own indentation doesn't need to match anything);
    # line numbers are pinned to this exact nixpkgs-pinned wvkbd version.
    #
    # Applied highest-original-line-number first: an `a` insertion shifts
    # every line below it down, so editing top-to-bottom would make each
    # later sed target the wrong (pre-shift) line number. Doing it in
    # descending order means every target is still at its original,
    # unshifted line number when its turn comes.
    postPatch = (old.postPatch or "") + ''
      # after the -H case, before the -L case (main.c:905-911)
      sed -i '910a\
        } else if ((!strcmp(argv[i], "-W")) || (!strcmp(argv[i], "--width"))) {\
            if (i >= argc - 1) {\
                usage(argv[0]);\
                exit(1);\
            }\
            surface_width = atoi(argv[++i]);\
            if (surface_width > 0) {\
                anchor = ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;\
            }' main.c

      # the set_size call (main.c:714)
      sed -i '714s/.*/    zwlr_layer_surface_v1_set_size(layer_surface, surface_width, height);/' main.c

      # redimension_keyboard() (main.c:505) hardcodes keyboard.w to the
      # full-output probe width regardless of what was requested via
      # set_size. The real layer surface's configure event legitimately
      # echoes back our requested (narrower) width, so keyboard.w then
      # never matches the compositor's configure -- main.c's mismatch
      # check (line 525: `keyboard.w != w`) treats that as "not what we
      # expected" and loops hide()/show() forever, never reaching
      # kbd_resize/drawing. Verified live: layer registers at the right
      # geometry but sits permanently inactive (hyprctl layers: `a: 0`),
      # nothing ever drawn.
      sed -i '505s/.*/    keyboard.w = surface_width > 0 ? surface_width : available_width;/' main.c

      # after the `anchor` declaration (main.c:62-64)
      sed -i '64a\
      static uint32_t surface_width = 0; /* 0 = fill horizontally; --width overrides */' main.c

      # keys_full (the default primary layer) only -- keys_full_wide has an
      # identical Compose-key line at a different address, deliberately
      # left alone.
      sed -i '237s/.*/  {"Sup", "Sup", 1.0, Mod, Super, .scheme = 1},/' layout.mobintl.h
    '';
  });
in

{
  # wvkbd: the only runtime dependency oskToggle spawns/kills.
  home.packages = [ wvkbdFloating ];

  programs.dank-material-shell.plugins = {
    oskToggle = {
      enable = true;
      src = ./plugins/osk-toggle;
    };

    noSleep = {
      enable = true;
      src = ./plugins/no-sleep;
    };

    rotationLock = {
      enable = true;
      src = ./plugins/rotation-lock;
      # QML can't read osConfig.wm.compositor itself -- ships it through
      # plugin_settings.json instead, alongside the same monitor name
      # wayland/niri.nix and wayland/hyprland.nix hardcode for the
      # autorotate listener this plugin kills/respawns.
      settings = {
        compositor = osConfig.wm.compositor;
        monitor = "eDP-1";
      };
    };
  };
}
