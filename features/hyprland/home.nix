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
    DMS's No Sleep plugin (features/dms/plugins/no-sleep) inhibits
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
  home.packages = lib.mkIf (osConfig.my.desktop.compositor == "hyprland") [
    pkgs.grimblast
    iioHyprlandWithTransformFix
    # iio-hyprland shells out to `hyprctl -j monitors | jq` internally; without
    # jq in PATH it fails immediately and aborts uncleanly (dbus_disconnect
    # crash) instead of just erroring on the missing monitor lookup.
  ];

  wayland.windowManager.hyprland = {
    enable = osConfig.my.desktop.compositor == "hyprland";

    # Lua, not hyprlang. Verified against this exact build's own source
    # (0.56.0's src/config/lua/bindings/*.cpp) rather than assumed from docs
    # of a fast-moving pre-1.0 API -- see extraConfig below for API notes.
    configType = "lua";

    settings = lib.mkIf (osConfig.my.desktop.compositor == "hyprland") {
      /*
        Everything below is ONE hl.config({...}) call: the Lua renderer emits
        `hl.<name>(...)` per top-level settings key, and `config` is the
        generic "any hyprlang-equivalent value" sink -- general, decoration,
        input, gestures, group, animations, scrolling, binds all nest inside
        it rather than getting their own top-level hl.<category>() call.
      */
      config = {
        general = {
          gaps_in = 2;
          gaps_out = 4;
          border_size = 0;
          layout = "scrolling";
          # Ask 2: resize by dragging a window's edge/gap, with mouse or
          # finger -- both route through the same click-and-drag hit-test,
          # so enabling this covers touch too (verified against 0.56.0
          # source: general:resize_on_border, default false).
          resize_on_border = true;
          # border_size = 0 above means there is no visible border to grab;
          # this extends the invisible hitbox around the window edge instead
          # (general:extend_border_grab_area, px, default 15 -- kept at
          # default, generous enough for a finger).
          extend_border_grab_area = 15;
          hover_icon_on_border = true;
        };

        /*
          DMS's Hyprland theming writes two Lua snippets, each its own
          hl.config call: colors.lua (general.col.*, group.col.*) and
          layout.lua (gaps_in/gaps_out/border_size/decoration.rounding).
          hyprlang could never source either -- hence the static snapshot
          this replaced.

          colors.lua is now required live (extraConfig) -- it only touches
          fields nothing else here sets, so there's nothing to race.
          layout.lua is deliberately NOT required: it sets border_size = 2,
          and this config keeps border_size = 0 on purpose (the touchscreen
          workspace-swipe activation strip below is
          (gaps_out + border_size) / screen_height -- widening border_size
          silently widens that strip). gaps_in/gaps_out/rounding stay static
          snapshots below, same limitation as before, now isolated to just
          those three values instead of colors too.
        */

        # Niri's touchpad block explicitly enables natural-scroll; Hyprland
        # has no input block at all here, defaulting to non-natural (i.e.
        # inverted relative to what niri was doing).
        input.touchpad.natural_scroll = true;

        /*
          Ask 1, root cause (verified against 0.56.0 source, not guessed):
          Super+H/L (movefocus l/r) direction-queries "is there a window to
          my left/right?" -- a maximized window fills the screen, so the
          query finds nothing and the dispatcher silently no-ops. That's
          binds:movefocus_cycles_fullscreen (default false); enabling it
          makes movefocus cycle through fullscreen/maximized windows instead
          of finding no neighbor. src/config/shared/actions/ConfigActions.cpp,
          Actions::moveFocus: the window-to-change-to is only computed via
          the fullscreen-aware cycle query when this is true.

          Super+J/K (workspace e∓1) and the touchscreen swipe (lisgd ->
          `hyprctl dispatch workspace e±1`, the SAME dispatcher) are a
          separate, NOT YET RESOLVED question -- I traced the entire
          changeWorkspace call chain (resolveWorkspaceForChange ->
          Actions::changeWorkspace -> CMonitor::changeWorkspace) in 0.56.0
          source and found no fullscreen/maximize gate anywhere in it: the
          switch and refocus proceed unconditionally regardless of the
          outgoing window's fullscreen state. So this setting doesn't touch
          J/K's problem, and neither should any Hyprland-level fix I could
          find. Left as a real open item; see the chat for what to check
          empirically (hyprctl workspaces active ID before/after, whether the
          emacs `maximize on` windowrule is just re-applying on the
          destination workspace too) before adding a workaround for a cause
          that isn't confirmed yet.
        */
        binds.movefocus_cycles_fullscreen = true;

        /*
          3-finger swipe drags/moves the focused window around; 4-finger
          swipe switches workspaces. Vertical to match niri's
          vertical-workspace model (workspaces animation style below must
          also be "slidevert" -- the swipe's up/down vs left/right behavior
          is derived from the animation style, not just this setting).

          Hyprland's only touchscreen gesture: a single-finger swipe from the
          screen EDGE, switching workspaces. Complements the lisgd daemon
          (features/touch-gestures) rather than replacing it -- that handles
          multi-finger swipes anywhere on the panel.

          The activation strip is (gaps_out + border_size) / screen_height,
          so with gaps_out = 4 and border_size = 0 it is four pixels. Enabled
          because it costs nothing and is occasionally hit by
          accident-turned-habit, but it is not the mechanism to rely on.
          Widening it means widening the gaps, which is not worth it.

          The axis follows the workspaces animation style, not this setting:
          "slidevert" below makes it top/bottom edges, matching the
          touchpad's 4-finger vertical gesture.
        */
        gestures = {
          workspace_swipe_touch = true;
          workspace_swipe_touch_invert = false;
        };

        # group.col.* comes from require("dms.colors") in extraConfig, same
        # as general's border colors -- DMS's colors.lua sets both in one
        # hl.config call (verified against its actual generated content), so
        # setting them here too would just race the same fields against it.

        decoration = {
          rounding = 16;
          # Glassmorphism: true backdrop blur behind translucent surfaces
          # (DMS panels get alpha < 1 via its transparency settings; the
          # layer_rule in extraConfig below opts the dms namespace into this
          # blur).
          blur = {
            enabled = true;
            size = 8;
            passes = 3;
            vibrancy = 0.17;
            ignore_opacity = true;
            popups = true;
            # Frost texture: over dark/flat backdrops (e.g. the wallpaper
            # strip behind the bar's exclusive zone -- windows never go
            # under it), plain blur is invisible. Noise + slight brightness
            # lift make the glass read as glass regardless of what's behind
            # it.
            noise = 0.02;
            brightness = 1.1;
            contrast = 1.0;
          };
        };

        /*
          Native scrolling layout (Hyprland >=0.55, src/layout/algorithm/tiled/scrolling) —
          niri-like columns, no plugin needed. column_width matches niri's
          layout.default-column-width.proportion = 0.5 from features/niri/home.nix.
        */
        scrolling = {
          column_width = 0.5;
          fullscreen_on_one_column = true;
          follow_focus = true;
        };

        # animations.enabled is a real scalar hyprlang value, so it belongs
        # here; the actual curve/speed data does NOT (see extraConfig's
        # hl.animation calls below for why).
        animations.enabled = true;

        # XWayland surfaces on this 1.5-scaled panel get upscaled by the
        # compositor and look pixelated (first seen on galaxy-buds-client,
        # an Avalonia/X11 app). force_zero_scaling makes XWayland render at
        # scale 1 -- crisp, but each X11 app is then responsible for its own
        # DPI scaling, which for Avalonia the AVALONIA_GLOBAL_SCALE_FACTOR
        # env below provides. Other-toolkit X11 apps that don't self-scale
        # will render small until given their own toolkit's scale env
        # (GDK_SCALE etc.) -- deliberate trade: crisp-but-small beats
        # blurry, and this host runs almost everything native Wayland.
        xwayland.force_zero_scaling = true;
      };

      /*
        Touchpad multi-finger gestures. hl.gesture({fingers, direction, action}) --
        one call per list element; direction values verified against
        TrackpadGestures.cpp's dirForString ("swipe" for the free-drag verb,
        "vertical"/"horizontal" for axis-locked ones -- NOT the legacy
        "3, swipe, move" string form, which Lua mode doesn't parse at all).
      */
      gesture = [
        # 3-finger free drag/move of the focused window.
        {
          fingers = 3;
          direction = "swipe";
          action = "move";
        }
        # 4-finger vertical swipe: workspace switch, matching the touchscreen
        # gesture direction above and the "slidevert" animation style.
        {
          fingers = 4;
          direction = "vertical";
          action = "workspace";
        }
        # scroll_move (snake_case -- verified against source, NOT the legacy
        # dispatcher's "scrollMove" spelling, which errors here:
        # "hl.gesture: unknown action \"scrollMove\""): purpose-built gesture
        # for the scrolling layout's tape -- live momentum + snap-to-column
        # (gestures:scrolling:* defaults handle it).
        {
          fingers = 4;
          direction = "horizontal";
          action = "scroll_move";
        }
      ];
    };

    /*
      Hand-written Lua rather than the settings-attrset DSL, for everything
      whose Nix->Lua rendering would need mkLuaInline gymnastics anyway
      (binds threading a `mod` variable through dispatcher-call expressions).
      Every hl.* call below is verified against this exact build's own
      source (0.56.0, src/config/lua/bindings/*.cpp), not assumed from docs
      of a fast-moving pre-1.0 API:
        - hl.bind(key_string, dispatcher_call, opts?) -- LuaBindingsToplevel.cpp:132.
          key_string: "+"-separated tokens, mods first ("SUPER + SHIFT + Q").
        - hl.dsp.* dispatcher table -- LuaBindingsDispatchers.cpp:1339
          (registerDispatcherBindings), enumerated exhaustively, not guessed.
        - hl.env(name, value), hl.monitor({output=...}), hl.window_rule({...}),
          hl.layer_rule({...}) -- LuaBindingsConfigRules.cpp.
        - hl.exec_cmd(cmd) at top level (NOT hl.dsp.exec_cmd, which is the
          bind-dispatcher-factory form) runs immediately as the script loads
          -- the exec-once equivalent. LuaBindingsToplevel.cpp:321.
    */
    extraConfig = ''
      local mod = "SUPER"

      -- DMS's cursorSettings plumbing is niri-only (cursorSettings.niri.hideWhenTyping);
      -- Hyprland never gets these applied, so it falls back to its own built-in
      -- hyprcursor theme. Set both XCURSOR_* (X/Wayland apps) and HYPRCURSOR_*
      -- (Hyprland's native cursor renderer) so it's consistent everywhere.
      -- Bibata-Modern-Classic-Glass = Bibata-Modern-Classic with alpha
      -- multiplied down, generated in features/cursor-theme/home.nix (home.pointerCursor
      -- there also enforces it via dconf + ~/.icons/default so apps can't
      -- resolve a different theme). No hyprcursor manifest; Hyprland falls
      -- back to the XCursor theme of the same name, which is intended.
      hl.env("XCURSOR_THEME", "Bibata-Modern-Classic-Glass")
      hl.env("XCURSOR_SIZE", "24")
      hl.env("HYPRCURSOR_THEME", "Bibata-Modern-Classic-Glass")
      hl.env("HYPRCURSOR_SIZE", "24")
      -- Qt apps outside Plasma (dolphin, kdenlive, ...) have no platform
      -- theme and fall back to a broken mixed palette (black-on-black text).
      -- qt6ct is installed and DMS's matugen already generates its palette
      -- (~/.config/qt6ct -> DankMatugen.colors) -- this activates it.
      -- This alone is NOT sufficient -- plugin discovery, qt6ct.conf
      -- contents, and KDE apps' KColorSchemeManager each needed their own
      -- fix. See features/qt-theming/nixos.nix (QT_PLUGIN_PATH +
      -- the full debugging story) and features/qt-theming/
      -- qt-theming.nix (kdeglobals + qt6ct.conf enforcement).
      hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
      -- Pairs with xwayland.force_zero_scaling in the config table above:
      -- XWayland now renders at scale 1, so Avalonia apps
      -- (galaxy-buds-client) must scale themselves. Avalonia reads this env
      -- var and accepts fractional values, unlike GDK_SCALE. Kept in sync
      -- with the monitor scale via my.desktop.primaryOutputScale.
      hl.env("AVALONIA_GLOBAL_SCALE_FACTOR", "${osConfig.my.desktop.primaryOutputScale}")

      -- DMS's own live colors -- see the "config" table's decoration/general
      -- comment above for why layout.lua (gaps/border/rounding) is NOT
      -- required here.
      do
        local xdg = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
        package.path = xdg .. "/hypr/?.lua;" .. xdg .. "/hypr/?/init.lua;" .. package.path
      end
      require("dms.colors")

      -- Hyprland's stock animation speeds read as sluggish coming from
      -- niri. NOT a field of hl.config's "animations" table: "animation" is
      -- not a real scalar hyprlang config value (only animations:enabled
      -- is, hence that staying in the config table above) -- it's a
      -- repeatable curve/speed RULE, which Lua mode exposes only through
      -- this dedicated function (verified: putting it inside hl.config did
      -- not error, it just silently did nothing, leaving Hyprland's default
      -- animation timings active -- "extremely slow" was this, not a units
      -- mistake).
      --
      -- `enabled` is required on every call despite defaulting to true in
      -- the C++ parser's own constructor: parseTableField() (Lua bindings
      -- internal helper) treats ANY missing table field as a hard error
      -- ("missing required field") before the parser object's constructor
      -- default is ever consulted -- that default only matters for a value
      -- parseTableField already found and is parsing, not for whether the
      -- field may be omitted. Confirmed live: leaving it out errored
      -- "missing required field \"enabled\"" on all five calls.
      hl.animation({ leaf = "global", enabled = true, speed = 4, bezier = "default" })
      hl.animation({ leaf = "windows", enabled = true, speed = 3, bezier = "default" })
      hl.animation({ leaf = "border", enabled = true, speed = 3, bezier = "default" })
      hl.animation({ leaf = "fade", enabled = true, speed = 3, bezier = "default" })
      -- slidevert: vertical slide, matching niri's vertical workspace model
      -- and the gesture's vertical swipe direction above.
      hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "default", style = "slidevert" })

      -- Auto-scale differs between compositors (Hyprland picked 2.0 for this
      -- 2880x1800 panel; niri's own auto heuristic apparently picked something
      -- smaller, hence text/buttons looking oversized after switching). Pin
      -- explicitly so it doesn't depend on Hyprland's auto-detection. Output name
      -- and scale both come from the host -- see my.desktop.primaryOutput.
      hl.monitor({
        output = "${osConfig.my.desktop.primaryOutput}",
        mode = "preferred",
        position = "auto",
        scale = "${osConfig.my.desktop.primaryOutputScale}",
      })

      -- iio-hyprland: reads iio-sensor-proxy orientation over D-Bus, rotates the
      -- eDP-1 output and touch input transform automatically (accel_3d + hinge
      -- sensors confirmed present via /sys/bus/iio/devices; enabled in hardware.nix).
      -- NO "dms run" here: systemd already starts dms.service via
      -- graphical-session.target (uwsm activates it) -- an exec-once copy runs
      -- a second, unmanaged instance (observed: two bars, hyprland-parented
      -- `dms run` without --session alongside dms.service's `dms run --session`).
      -- Same reasoning as the niri side's spawn-at-startup comment.
      hl.exec_cmd("iio-hyprland ${osConfig.my.desktop.primaryOutput}")

      -- Glassmorphism for DMS layer surfaces. ignore_alpha skips
      -- near-fully-transparent pixels (the empty regions of the bar
      -- surface) so they don't render as a hazy smear.
      hl.layer_rule({ match = { namespace = "^(dms.*)$" }, no_anim = true, blur = true, ignore_alpha = 0.05 })
      -- Same glass treatment for the OSK (features/dms/plugins/osk-toggle):
      -- wvkbd's own --alpha only sets its drawn pixels' transparency, the
      -- actual frosted backdrop still needs Hyprland's blur behind it.
      hl.layer_rule({ match = { namespace = "^(wvkbd)$" }, blur = true, ignore_alpha = 0.05 })

      hl.window_rule({ match = { class = "^(emacs)$" }, maximize = true })
      hl.window_rule({ match = { class = "^(org.gnu.emacs)$" }, maximize = true })
      -- Glassmorphism: translucent KDE apps; backdrop blur applies to
      -- translucent windows automatically (decoration.blur). kdeconnect
      -- covers all its windows (.app, .sms, -indicator, ...).
      hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, opacity = "0.65 0.65" })
      hl.window_rule({ match = { class = "^(org\\.kde\\.kdeconnect.*)$" }, opacity = "0.65 0.65" })
      -- Claude Desktop: app_id from the deb's desktop-file StartupWMClass
      -- (Chromium derives it from package.json desktopName). Same 0.65 as
      -- the KDE apps -- the package forces its dark backgrounds to #000
      -- (see packages/claude-desktop/package.nix), so it composites
      -- identically to kitty/dolphin.
      hl.window_rule({ match = { class = "^(com\\.anthropic\\.Claude)$" }, opacity = "0.65 0.65" })
      -- Galaxy Buds client: small settings-style utility, better floating
      -- than as a full tape column. Class from the package's own
      -- makeDesktopItem name (= meta.mainProgram = "GalaxyBudsClient",
      -- which Avalonia also uses for WM_CLASS). If the rule doesn't bite,
      -- verify the real class with `hyprctl clients | grep -i buds`.
      -- Its XWayland pixelation is handled globally above
      -- (xwayland.force_zero_scaling + AVALONIA_GLOBAL_SCALE_FACTOR), not
      -- per-window -- force_zero_scaling has no per-window form.
      hl.window_rule({ match = { class = "^(GalaxyBudsClient)$" }, float = true })

      -- ============================================================
      -- Binds. Key-layout aligned with end-4/dots-hyprland's
      -- keybinds.lua where it has a real Hyprland-dispatcher
      -- equivalent; its quickshell:* global-IPC actions (overview,
      -- sidebars, OSK, cheatsheet -- end-4's own shell's protocol, which
      -- DMS does not implement) are NOT ported -- see the chat for the
      -- explicit list of what that leaves out.
      -- ============================================================

      -- DMS / apps (unchanged from the pre-Lua config)
      hl.bind(mod .. " + space", hl.dsp.exec_cmd("dms ipc call spotlight toggle"))
      hl.bind(mod .. " + I", hl.dsp.exec_cmd("dms ipc call settings toggle"))
      hl.bind(mod .. " + Return", hl.dsp.exec_cmd("kitty"))
      hl.bind(mod .. " + W", hl.dsp.exec_cmd("firefox"))
      hl.bind(mod .. " + E", hl.dsp.exec_cmd("emacsclient -c"))
      hl.bind(mod .. " + A", hl.dsp.exec_cmd("dms ipc call plugins toggle aiAssistant"))
      hl.bind(mod .. " + N", hl.dsp.exec_cmd("dms ipc call notifications toggle"))
      hl.bind(mod .. " + P", hl.dsp.exec_cmd("dms ipc call notepad toggle"))
      hl.bind(mod .. " + V", hl.dsp.exec_cmd("dms ipc call clipboard toggle"))
      hl.bind(mod .. " + X", hl.dsp.exec_cmd("dms ipc call powermenu toggle"))
      hl.bind(mod .. " + M", hl.dsp.exec_cmd("dms ipc call processlist toggle"))
      hl.bind(mod .. " + ALT + N", hl.dsp.exec_cmd("dms ipc call night toggle"))
      hl.bind("SUPER + ALT + L", hl.dsp.exec_cmd("dms ipc call lock lock"))
      -- Compositor-level IME toggle, same logic as niri.nix's Hangul bind.
      hl.bind("Hangul", hl.dsp.exec_cmd("${hangulToggle}"))

      -- Window management
      hl.bind(mod .. " + Q", hl.dsp.window.close())
      hl.bind(mod .. " + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
      -- niri's maximize-column, now a real TOGGLE on Mod+D (end-4's key for
      -- it; Mod+D is free now that its earlier weirdness is understood --
      -- it was never a DMS collision, just Hyprland's MAXIMIZED state
      -- dropping gaps/rounding, see the git log of this file for the whole
      -- misdiagnosis saga). `colresize 1` keeps the window a normal tiled
      -- column -- gaps and rounding intact -- unlike MAXIMIZED.
      --
      -- The toggle is STATE-FREE on purpose: no stored flag to go stale
      -- when Mod+R or a mouse edge-drag changes the width behind its back.
      -- It reads the focused window's actual laid-out width against the
      -- monitor's usable logical width and picks the direction each press:
      --   window object: .size (GEOMETRIC_GOAL layout px), .floating,
      --   .monitor -- LuaWindow.cpp
      --   monitor object: .size (PIXEL size -- divide by .scale for
      --   logical), .transform (odd = rotated 90°: swap w/h -- this is a
      --   convertible with autorotate, so it matters), .reserved
      --   (bar exclusive zone) -- LuaMonitor.cpp
      -- 0.9 threshold: a full column is usable minus 2*gaps_out (8px);
      -- the next preset down is 0.66, comfortably below.
      hl.bind(mod .. " + D", function()
        local w = hl.get_active_window()
        if not w or w.floating then return end
        local m = w.monitor
        if not m then return end
        local pw = (m.transform % 2 == 1) and m.size.height or m.size.width
        local usable = pw / m.scale - m.reserved.left - m.reserved.right
        if w.size.x >= usable * 0.9 then
          -- 0.5 = scrolling.column_width in the config table above; keep in sync.
          hl.dispatch(hl.dsp.layout("colresize 0.5"))
        else
          hl.dispatch(hl.dsp.layout("colresize 1"))
        end
      end)
      hl.bind(mod .. " + ALT + space", hl.dsp.window.float())
      -- end-4's Mod+P is "pin"; this config's Mod+P is already DMS's
      -- notepad toggle (see above), so pin goes on Mod+Alt+P instead of
      -- silently overwriting an existing, deliberately-chosen bind.
      hl.bind(mod .. " + ALT + P", hl.dsp.window.pin())
      -- niri's Mod+Shift+V (switch focus between floating/tiling) has no
      -- direct hyprland dispatcher; `togglegroup` is a different concept
      -- (window grouping), so it's dropped rather than mis-mapped.

      -- niri's Mod+R (switch-preset-column-width) -> scrolling layout's
      -- colresize +conf, which cycles through scrolling:explicit_column_widths.
      hl.bind(mod .. " + R", hl.dsp.layout("colresize +conf"))

      -- Focus movement (h/j/k/l + arrows). hl.dsp.focus is the single
      -- dispatcher covering movefocus/focusmonitor/focus-workspace by
      -- which field its table has -- direction here.
      hl.bind(mod .. " + left", hl.dsp.focus({ direction = "left" }))
      hl.bind(mod .. " + down", hl.dsp.focus({ direction = "down" }))
      hl.bind(mod .. " + up", hl.dsp.focus({ direction = "up" }))
      hl.bind(mod .. " + right", hl.dsp.focus({ direction = "right" }))
      -- H/L go through the scrolling layout's OWN focus navigation, not
      -- movefocus. movefocus is geometry-based and the
      -- movefocus_cycles_fullscreen fallback is explicitly bypassed for
      -- layout-managed fullscreen (Actions::moveFocus checks
      -- !layoutManagedFS; the scrolling layout registers its own fullscreen
      -- handler, so its windows ALWAYS take that bypass) -- which is why
      -- H/L stayed dead on maximized windows even after enabling that
      -- setting. `layoutmsg focus l/r` walks the tape's column data
      -- structure instead of screen geometry (ScrollingAlgorithm.cpp,
      -- "focus" branch: pure column->prev/next, no fullscreen gate), so it
      -- works identically maximized or not -- and matches niri's
      -- focus-column semantics, which is what H/L meant here originally.
      -- Arrows stay movefocus: layoutmsg only knows tiled tape members, so
      -- arrows remain the way to reach floating windows.
      hl.bind(mod .. " + H", hl.dsp.layout("focus l"))
      hl.bind(mod .. " + L", hl.dsp.layout("focus r"))
      -- Workspace cycle among EXISTING workspaces ("e±1"), same string
      -- syntax as the legacy `workspace, e-1` dispatcher -- hl.dsp.focus's
      -- workspace-selector overload hands it to the identical parser.
      hl.bind(mod .. " + J", hl.dsp.focus({ workspace = "e-1" }))
      hl.bind(mod .. " + K", hl.dsp.focus({ workspace = "e+1" }))
      hl.bind(mod .. " + Page_Down", hl.dsp.focus({ workspace = "e-1" }))
      hl.bind(mod .. " + Page_Up", hl.dsp.focus({ workspace = "e+1" }))
      hl.bind(mod .. " + CTRL + U", hl.dsp.window.move({ workspace = "e-1", follow = true }))
      hl.bind(mod .. " + CTRL + I", hl.dsp.window.move({ workspace = "e+1", follow = true }))

      -- Move window (direction)
      hl.bind(mod .. " + CTRL + left", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + CTRL + down", hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + CTRL + up", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + CTRL + right", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + CTRL + H", hl.dsp.window.move({ direction = "left" }))
      hl.bind(mod .. " + CTRL + J", hl.dsp.window.move({ direction = "down" }))
      hl.bind(mod .. " + CTRL + K", hl.dsp.window.move({ direction = "up" }))
      hl.bind(mod .. " + CTRL + L", hl.dsp.window.move({ direction = "right" }))
      hl.bind(mod .. " + CTRL + Page_Down", hl.dsp.window.move({ workspace = "e-1", follow = true }))
      hl.bind(mod .. " + CTRL + Page_Up", hl.dsp.window.move({ workspace = "e+1", follow = true }))

      -- Resize (niri's Mod+Minus/Equal, Mod+Shift+Minus/Equal). BEHAVIOR
      -- CHANGE from the pre-Lua config: legacy `resizeactive` took
      -- percentage-of-current-size ("-10% 0"); hl.dsp.window.resize's table
      -- form only takes pixel x/y (verified against source -- no percentage
      -- support), so this is now a fixed 160px/90px step regardless of the
      -- window's current size.
      hl.bind(mod .. " + minus", hl.dsp.window.resize({ x = -160, y = 0, relative = true }))
      hl.bind(mod .. " + equal", hl.dsp.window.resize({ x = 160, y = 0, relative = true }))
      hl.bind(mod .. " + SHIFT + minus", hl.dsp.window.resize({ x = 0, y = -90, relative = true }))
      hl.bind(mod .. " + SHIFT + equal", hl.dsp.window.resize({ x = 0, y = 90, relative = true }))

      -- Monitor focus
      hl.bind(mod .. " + SHIFT + left", hl.dsp.focus({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + down", hl.dsp.focus({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + up", hl.dsp.focus({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + right", hl.dsp.focus({ monitor = "r" }))

      -- Move window to monitor (niri's Mod+Shift+Ctrl+...)
      hl.bind(mod .. " + SHIFT + CTRL + left", hl.dsp.window.move({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + CTRL + down", hl.dsp.window.move({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + CTRL + up", hl.dsp.window.move({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + CTRL + right", hl.dsp.window.move({ monitor = "r" }))
      hl.bind(mod .. " + SHIFT + CTRL + H", hl.dsp.window.move({ monitor = "l" }))
      hl.bind(mod .. " + SHIFT + CTRL + J", hl.dsp.window.move({ monitor = "d" }))
      hl.bind(mod .. " + SHIFT + CTRL + K", hl.dsp.window.move({ monitor = "u" }))
      hl.bind(mod .. " + SHIFT + CTRL + L", hl.dsp.window.move({ monitor = "r" }))

      -- Workspaces 1-9
      for i = 1, 9 do
        hl.bind(mod .. " + " .. tostring(i), hl.dsp.focus({ workspace = i }))
        hl.bind(mod .. " + CTRL + " .. tostring(i), hl.dsp.window.move({ workspace = i, follow = true }))
      end

      hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())
      hl.bind("Print", hl.dsp.exec_cmd("grimblast copy area"))
      hl.bind("CTRL + Print", hl.dsp.exec_cmd("grimblast copy screen"))
      hl.bind("ALT + Print", hl.dsp.exec_cmd("grimblast copy active"))
      hl.bind(mod .. " + SHIFT + P", hl.dsp.dpms({ action = "off" }))

      -- Media/brightness keys: repeating + fires even while locked.
      hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
      hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
      hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd('dms ipc call brightness increment 5 ""'), { locked = true, repeating = true })
      hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd('dms ipc call brightness decrement 5 ""'), { locked = true, repeating = true })

      -- Mute/lid: locked (fires once already locked) but not repeating.
      hl.bind("XF86AudioMute", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })
      hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("dms ipc call audio micmute"), { locked = true })
      hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd("${lidClose}"), { locked = true })
      hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd("${lidOpen}"), { locked = true })
    '';
  };
}
