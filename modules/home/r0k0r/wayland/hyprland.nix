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
    iio-hyprland only ever sends hyprctl a *partial* monitor rule --
    "keyword monitor eDP-1,transform,N" -- which patches the transform
    field without Hyprland recomputing the transformed (width/height
    swapped) box. Verified live: bar/dock/background stayed at landscape
    geometry after a bare transform,1, and only snapped to portrait once
    resolution/position/scale were restated alongside it in the same
    keyword command.

    This shim sits in front of the real hyprctl (PATH-shadowed for
    iio-hyprland only, below) and rewrites just that one command: look up
    the monitor's current mode via `hyprctl monitors -j` (same call
    iio-hyprland already makes for its own monitor-id lookup), then
    reissue the batch with a full rule instead of the bare transform.
    Anything else passes through untouched.
  */
  hyprctlTransformShim = pkgs.writeShellScriptBin "hyprctl" ''
    real=${pkgs.hyprland}/bin/hyprctl
    if [ "$1" = "--batch" ] && [[ "$2" == *"keyword monitor "*",transform,"* ]]; then
      if [[ "$2" =~ keyword\ monitor\ ([^,]+),transform,([0-9]+) ]]; then
        mon="''${BASH_REMATCH[1]}"
        xform="''${BASH_REMATCH[2]}"
        if [ "$xform" = "0" ]; then
          # Returning to transform 0 is its own separate bug: even the full
          # monitor rule below leaves layer-shell clients stuck at the
          # rotated geometry here, though hyprctl monitors correctly
          # reports transform:0 -- verified live. `reload` reliably forces
          # the resync, and since the static config has no transform
          # override, it also lands exactly on the landscape state wanted.
          exec "$real" reload
        fi
        read -r w h r x y scale < <("$real" monitors -j | ${pkgs.jq}/bin/jq -r --arg m "$mon" \
          '.[] | select(.name == $m) | "\(.width) \(.height) \(.refreshRate) \(.x) \(.y) \(.scale)"')
        if [ -n "''${w:-}" ]; then
          full="monitor $mon,''${w}x''${h}@''${r},''${x}x''${y},''${scale},transform,$xform"
          patched="''${2/keyword monitor $mon,transform,$xform/keyword $full}"
          exec "$real" --batch "$patched"
        fi
      fi
    fi
    exec "$real" "$@"
  '';

  # Only iio-hyprland's own hyprctl calls go through the shim -- everything
  # else in the session (DMS, terminal, keybinds) keeps using the real one.
  iioHyprlandWithTransformFix = pkgs.writeShellScriptBin "iio-hyprland" ''
    export PATH="${hyprctlTransformShim}/bin:$PATH"
    exec ${pkgs.iio-hyprland}/bin/iio-hyprland "$@"
  '';

  /*
    DMS's No Sleep plugin (gui/dms/plugins/no-sleep) inhibits
    idle:sleep:handle-lid-switch, which blocks logind from taking ANY
    action on lid close -- including its normal screen-off -- leaving the
    display lit and unlocked inside a closed lid for as long as the
    inhibitor holds. Rather than have the plugin manage its own lock/DPMS
    watcher (a long-running process, with all the QML-lifetime pitfalls
    that hit rotation-lock's respawn), let Hyprland handle the lid switch
    directly: it reads the raw libinput switch event itself, independent of
    logind entirely, via a static keybind that's never spawned/torn down
    by any widget.

    Both scripts gate on whether the plugin's inhibitor is actually held
    (pgrep on its --who= tag -- the plugin's only externally-visible
    marker) so they only act while No Sleep is on; otherwise they no-op and
    logind's normal suspend flow (already locked via
    session-lock-hooks.nix's sleep.target hook) proceeds untouched.
  */

  lidClose = pkgs.writeShellScript "dms-lid-close" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
      dms ipc call lock lock
      hyprctl dispatch dpms off
    fi
  '';
  lidOpen = pkgs.writeShellScript "dms-lid-open" ''
    if ${pkgs.procps}/bin/pgrep -f -- "--who=DMS No Sleep plugin" >/dev/null; then
      hyprctl dispatch dpms on
    fi
  '';

in
{
  /*
    DMS's screenshot IPC (`dms ipc call niri screenshot*`) is documented as niri-only
    (requires niri 25.11+); no hyprland equivalent exists. Use grimblast, the standard
    Hyprland screen/window/area capture wrapper around grim+slurp+hyprctl, instead.
  */
  home.packages = lib.mkIf (osConfig.wm.compositor == "hyprland") [
    pkgs.grimblast
    iioHyprlandWithTransformFix
    # iio-hyprland shells out to `hyprctl -j monitors | jq` internally; without
    # jq in PATH it fails immediately and aborts uncleanly (dbus_disconnect
    # crash) instead of just erroring on the missing monitor lookup.
    pkgs.jq
  ];

  wayland.windowManager.hyprland = {
    enable = osConfig.wm.compositor == "hyprland";

    # Pin explicitly: home-manager >=26.05 defaults this to "lua" based on
    # home.stateVersion, which silently mangled our hyprlang bind strings
    # (e.g. "$mod" = "SUPER" -> invalid `hl.$mod("SUPER")` call) and can't
    # source DMS's plain-hyprlang colors/layout/outputs.conf files at all.
    configType = "hyprlang";

    settings = lib.mkIf (osConfig.wm.compositor == "hyprland") {
      "$mod" = "SUPER";

      /*
        DMS's Hyprland theming (Matugen colors + gaps/rounding) writes Lua snippets
        (~/.config/hypr/dms/{colors,layout}.lua using hl.config({...})), not the
        .conf files this module's `source=` used to point at (always empty ->
        rounding/focus-ring/border-color never applied). hyprlang can't source a
        .lua file, and DMS has no .conf output mode, so this is a static snapshot
        of the current DMS-generated values, not live-updating with dynamicTheming.
      */
      general = {
        "col.active_border" = "rgb(ffffff)";
        "col.inactive_border" = "rgb(929092)";
        gaps_in = 2;
        gaps_out = 4;
        border_size = 0;
        layout = "scrolling";
      };

      # Niri's touchpad block explicitly enables natural-scroll; Hyprland has no
      # input block at all here, defaulting to non-natural (i.e. inverted relative
      # to what niri was doing).
      input.touchpad.natural_scroll = true;

      # 3-finger swipe drags/moves the focused window around; 4-finger swipe
      # switches workspaces. Vertical to match niri's vertical-workspace model
      # (workspaces animation style below must also be "slidevert" — the swipe's
      # up/down vs left/right behavior is derived from the animation style, not
      # just this direction setting).
      gesture = [
        "3, swipe, move"
        "4, vertical, workspace"
        # scrollMove: purpose-built gesture for the scrolling layout's tape —
        # live momentum + snap-to-column (gestures:scrolling:* defaults handle it).
        "4, horizontal, scrollMove"
      ];

      # Real hyprlang keys mix separators: "category:col.field", not
      # "category:col:field" — a nested `col = {...}` attrset gets serialized
      # with `:` at every level, which doesn't exist ("does not exist" errors).
      # Flat string keys with the literal dot preserve the real key exactly.
      group = {
        "col.border_active" = "rgb(ffffff)";
        "col.border_inactive" = "rgb(929092)";
        "col.border_locked_active" = "rgb(ffb4ab)";
        "col.border_locked_inactive" = "rgb(929092)";
      };

      decoration = {
        rounding = 16;
        # Glassmorphism: true backdrop blur behind translucent surfaces
        # (DMS panels get alpha < 1 via its transparency settings; the
        # layerrule below opts the dms namespace into this blur).
        blur = {
          enabled = true;
          size = 8;
          passes = 3;
          vibrancy = 0.17;
          ignore_opacity = true;
          popups = true;
          # Frost texture: over dark/flat backdrops (e.g. the wallpaper strip
          # behind the bar's exclusive zone -- windows never go under it),
          # plain blur is invisible. Noise + slight brightness lift make the
          # glass read as glass regardless of what's behind it.
          noise = 0.02;
          brightness = 1.1;
          contrast = 1.0;
        };
      };

      # DMS's cursorSettings plumbing is niri-only (cursorSettings.niri.hideWhenTyping);
      # Hyprland never gets these applied, so it falls back to its own built-in
      # hyprcursor theme. Set both XCURSOR_* (X/Wayland apps) and HYPRCURSOR_*
      # (Hyprland's native cursor renderer) so it's consistent everywhere.
      # Bibata-Modern-Classic-Glass = Bibata-Modern-Classic with alpha
      # multiplied down, generated in gui/cursor.nix (home.pointerCursor
      # there also enforces it via dconf + ~/.icons/default so apps can't
      # resolve a different theme). No hyprcursor manifest; Hyprland falls
      # back to the XCursor theme of the same name, which is intended.
      env = [
        "XCURSOR_THEME,Bibata-Modern-Classic-Glass"
        "XCURSOR_SIZE,24"
        "HYPRCURSOR_THEME,Bibata-Modern-Classic-Glass"
        "HYPRCURSOR_SIZE,24"
        # Qt apps outside Plasma (dolphin, kdenlive, ...) have no platform
        # theme and fall back to a broken mixed palette (black-on-black text).
        # qt6ct is installed and DMS's matugen already generates its palette
        # (~/.config/qt6ct -> DankMatugen.colors) -- this activates it.
        # This alone is NOT sufficient -- plugin discovery, qt6ct.conf
        # contents, and KDE apps' KColorSchemeManager each needed their own
        # fix. See modules/nixos/desktop/qt-theming.nix (QT_PLUGIN_PATH +
        # the full debugging story) and modules/home/r0k0r/gui/
        # qt-theming.nix (kdeglobals + qt6ct.conf enforcement).
        "QT_QPA_PLATFORMTHEME,qt6ct"
      ];

      # eDP-1 auto-scale differs between compositors (Hyprland picked 2.0 for this
      # 2880x1800 panel; niri's own auto heuristic apparently picked something
      # smaller, hence text/buttons looking oversized after switching). Pin
      # explicitly so it doesn't depend on Hyprland's auto-detection.
      monitor = [ "eDP-1, preferred, auto, 1.5" ];

      # Hyprland's stock animation speeds read as sluggish coming from niri.
      animations = {
        enabled = true;
        animation = [
          "global, 1, 4, default"
          "windows, 1, 3, default"
          "border, 1, 3, default"
          "fade, 1, 3, default"
          # slidevert: vertical slide, matching niri's vertical workspace model
          # and the gesture's vertical swipe direction above.
          "workspaces, 1, 3, default, slidevert"
        ];
      };

      # iio-hyprland: reads iio-sensor-proxy orientation over D-Bus, rotates the
      # eDP-1 output and touch input transform automatically (accel_3d + hinge
      # sensors confirmed present via /sys/bus/iio/devices; enabled in hardware.nix).
      # NO "dms run" here: systemd already starts dms.service via
      # graphical-session.target (uwsm activates it) -- an exec-once copy runs
      # a second, unmanaged instance (observed: two bars, hyprland-parented
      # `dms run` without --session alongside dms.service's `dms run --session`).
      # Same reasoning as the niri side's spawn-at-startup comment.
      exec-once = [
        "iio-hyprland eDP-1"
      ];

      # New rule syntax (0.55+): each comma-separated element is "key value",
      # not the old bare-keyword form ("noanim" alone errors: "missing a value").
      layerrule = [
        "no_anim on, match:namespace ^(dms.*)$"
        # Glassmorphism for DMS layer surfaces. ignore_alpha skips
        # near-fully-transparent pixels (the empty regions of the bar
        # surface) so they don't render as a hazy smear.
        "blur on, match:namespace ^(dms.*)$"
        "ignore_alpha 0.05, match:namespace ^(dms.*)$"
        # Same glass treatment for the OSK (gui/dms/plugins/osk-toggle):
        # wvkbd's own --alpha only sets its drawn pixels' transparency, the
        # actual frosted backdrop still needs Hyprland's blur behind it.
        "blur on, match:namespace ^(wvkbd)$"
        "ignore_alpha 0.05, match:namespace ^(wvkbd)$"
      ];

      /*
        Native scrolling layout (Hyprland >=0.55, src/layout/algorithm/tiled/scrolling) —
        niri-like columns, no plugin needed. column_width matches niri's
        layout.default-column-width.proportion = 0.5 from wayland/niri.nix.
      */
      scrolling = {
        column_width = 0.5;
        fullscreen_on_one_column = true;
        follow_focus = true;
      };

      # DMS's Hangul toggle, mirrored from wayland/niri.nix.
      bind =
        [
          # Custom overrides (same as niri.nix).
          "$mod, space, exec, dms ipc call spotlight toggle"
          # niri's Mod+Comma (consume-window-into-column) has no scrolling-layout
          # equivalent (columns hold exactly one window on the tape); omitted.
          "$mod, I, exec, dms ipc call settings toggle"
          "$mod, Return, exec, kitty"
          "$mod, W, exec, firefox"
          "$mod, E, exec, emacsclient -c"
          "$mod, A, exec, dms ipc call plugins toggle aiAssistant"

          # DMS IPC toggles, replicated by hand (single source of truth: DMS's own
          # niri enableKeybinds module has no hyprland equivalent, see niri.nix).
          "$mod, N, exec, dms ipc call notifications toggle"
          "$mod, P, exec, dms ipc call notepad toggle"
          "$mod, V, exec, dms ipc call clipboard toggle"
          "$mod, X, exec, dms ipc call powermenu toggle"
          "$mod, M, exec, dms ipc call processlist toggle"
          "$mod ALT, N, exec, dms ipc call night toggle"
          "SUPER ALT, L, exec, dms ipc call lock lock"

          # Window management
          "$mod, Q, killactive,"
          "$mod, F, fullscreen, 0"
          "$mod SHIFT, F, fullscreen, 1"
          "$mod ALT, space, togglefloating,"
          # niri's Mod+Shift+V (switch focus between floating/tiling) has no
          # direct hyprland dispatcher; `togglegroup` is a different concept
          # (window grouping), so it's dropped rather than mis-mapped.

          # niri's Mod+R (switch-preset-column-width) -> scrolling layout's
          # colresize +conf, which cycles through scrolling:explicit_column_widths.
          "$mod, R, layoutmsg, colresize +conf"

          # Focus movement (h/j/k/l + arrows)
          "$mod, left, movefocus, l"
          "$mod, down, movefocus, d"
          "$mod, up, movefocus, u"
          "$mod, right, movefocus, r"
          "$mod, H, movefocus, l"
          "$mod, J, workspace, e-1"
          "$mod, K, workspace, e+1"
          "$mod, L, movefocus, r"
          "$mod, Page_Down, workspace, e-1"
          "$mod, Page_Up, workspace, e+1"
          "$mod CTRL, U, movetoworkspace, e-1"
          "$mod CTRL, I, movetoworkspace, e+1"

          # Move window
          "$mod CTRL, left, movewindow, l"
          "$mod CTRL, down, movewindow, d"
          "$mod CTRL, up, movewindow, u"
          "$mod CTRL, right, movewindow, r"
          "$mod CTRL, H, movewindow, l"
          "$mod CTRL, J, movewindow, d"
          "$mod CTRL, K, movewindow, u"
          "$mod CTRL, L, movewindow, r"
          "$mod CTRL, Page_Down, movetoworkspace, e-1"
          "$mod CTRL, Page_Up, movetoworkspace, e+1"

          # Resize (niri's Mod+Minus/Equal, Mod+Shift+Minus/Equal)
          "$mod, minus, resizeactive, -10% 0"
          "$mod, equal, resizeactive, 10% 0"
          "$mod SHIFT, minus, resizeactive, 0 -10%"
          "$mod SHIFT, equal, resizeactive, 0 10%"

          # Monitor focus
          "$mod SHIFT, left, focusmonitor, l"
          "$mod SHIFT, down, focusmonitor, d"
          "$mod SHIFT, up, focusmonitor, u"
          "$mod SHIFT, right, focusmonitor, r"

          # Move column to monitor (niri's Mod+Shift+Ctrl+...)
          "$mod SHIFT CTRL, left, movewindow, mon:l"
          "$mod SHIFT CTRL, down, movewindow, mon:d"
          "$mod SHIFT CTRL, up, movewindow, mon:u"
          "$mod SHIFT CTRL, right, movewindow, mon:r"
          "$mod SHIFT CTRL, H, movewindow, mon:l"
          "$mod SHIFT CTRL, J, movewindow, mon:d"
          "$mod SHIFT CTRL, K, movewindow, mon:u"
          "$mod SHIFT CTRL, L, movewindow, mon:r"

          # Workspaces 1-9
          "$mod, 1, workspace, 1"
          "$mod, 2, workspace, 2"
          "$mod, 3, workspace, 3"
          "$mod, 4, workspace, 4"
          "$mod, 5, workspace, 5"
          "$mod, 6, workspace, 6"
          "$mod, 7, workspace, 7"
          "$mod, 8, workspace, 8"
          "$mod, 9, workspace, 9"

          "$mod CTRL, 1, movetoworkspace, 1"
          "$mod CTRL, 2, movetoworkspace, 2"
          "$mod CTRL, 3, movetoworkspace, 3"
          "$mod CTRL, 4, movetoworkspace, 4"
          "$mod CTRL, 5, movetoworkspace, 5"
          "$mod CTRL, 6, movetoworkspace, 6"
          "$mod CTRL, 7, movetoworkspace, 7"
          "$mod CTRL, 8, movetoworkspace, 8"
          "$mod CTRL, 9, movetoworkspace, 9"

          "$mod SHIFT, E, exit,"
          ", Print, exec, grimblast copy area"
          "CTRL, Print, exec, grimblast copy screen"
          "ALT, Print, exec, grimblast copy active"
          "$mod SHIFT, P, dpms, off"
        ]
        ++ [
          # Compositor-level IME toggle, same logic as niri.nix's Hangul bind.
          ", Hangul, exec, ${hangulToggle}"
        ];

      bindel = [
        ", XF86AudioRaiseVolume, exec, dms ipc call audio increment 3"
        ", XF86AudioLowerVolume, exec, dms ipc call audio decrement 3"
        ", XF86MonBrightnessUp, exec, dms ipc call brightness increment 5 \"\""
        ", XF86MonBrightnessDown, exec, dms ipc call brightness decrement 5 \"\""
      ];

      bindl = [
        ", XF86AudioMute, exec, dms ipc call audio mute"
        ", XF86AudioMicMute, exec, dms ipc call audio micmute"
        # "l" flag (bindl) so these still fire once already locked -- lid
        # can close after a manual lock, not just trigger one.
        ", switch:on:Lid Switch, exec, ${lidClose}"
        ", switch:off:Lid Switch, exec, ${lidOpen}"
      ];

      # windowrulev2 is deprecated/removed (0.55+); plain windowrule now carries the
      # same multi-match syntax, but each element is "key value" (no bare keywords).
      windowrule = [
        "maximize on, match:class ^(emacs)$"
        "maximize on, match:class ^(org.gnu.emacs)$"
        # Glassmorphism: translucent KDE apps; backdrop blur applies to
        # translucent windows automatically (decoration:blur). kdeconnect
        # covers all its windows (.app, .sms, -indicator, ...).
        "opacity 0.65 0.65, match:class ^(org\\.kde\\.dolphin)$"
        "opacity 0.65 0.65, match:class ^(org\\.kde\\.kdeconnect.*)$"
        # Claude Desktop: app_id from the deb's desktop-file StartupWMClass
        # (Chromium derives it from package.json desktopName). Same 0.65 as
        # the KDE apps -- the package forces its dark backgrounds to #000
        # (see packages/claude-desktop/package.nix), so it composites
        # identically to kitty/dolphin.
        "opacity 0.65 0.65, match:class ^(com\\.anthropic\\.Claude)$"
      ];
    };
  };
}
