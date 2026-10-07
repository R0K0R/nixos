-- features/hyprland: the compositor's own Hyprland config.
--
-- Plain Lua, loaded by the generated ~/.config/hypr/hyprland.lua as
-- require("feat.hyprland") BEFORE every other feature's file (lib/hypr-lua.nix,
-- and the mkBefore note in home.nix). Values that come from Nix -- store paths
-- of the helper scripts in home.nix, host options -- arrive in `nix`.
--
-- Every hl.* call is verified against this exact build's own source (0.56,
-- src/config/lua/bindings/*.cpp), not assumed from docs of a fast-moving
-- pre-1.0 API:
--   - hl.bind(key_string, dispatcher_call, opts?) -- LuaBindingsToplevel.cpp:132.
--     key_string: "+"-separated tokens, mods first ("SUPER + SHIFT + Q").
--   - hl.dsp.* dispatcher table -- LuaBindingsDispatchers.cpp:1339
--     (registerDispatcherBindings), enumerated exhaustively, not guessed.
--   - hl.env(name, value), hl.monitor({output=...}), hl.window_rule({...}),
--     hl.layer_rule({...}) -- LuaBindingsConfigRules.cpp.
--   - hl.exec_cmd(cmd) at top level (NOT hl.dsp.exec_cmd, which is the
--     bind-dispatcher-factory form) runs immediately as the script loads
--     -- the exec-once equivalent. LuaBindingsToplevel.cpp:321.

local nix = require("nix.hyprland")
local mod = nix.mod

hl.config({
  general = {
    gaps_in = 2,
    gaps_out = 4,
    border_size = 0,
    layout = "scrolling",
    -- Ask 2: resize by dragging a window's edge/gap, with mouse or
    -- finger -- both route through the same click-and-drag hit-test,
    -- so enabling this covers touch too (verified against 0.56.0
    -- source: general:resize_on_border, default false).
    resize_on_border = true,
    -- border_size = 0 above means there is no visible border to grab;
    -- this extends the invisible hitbox around the window edge instead
    -- (general:extend_border_grab_area, px, default 15).
    --
    -- KEPT AT THE DEFAULT, because raising it does NOT help between two
    -- tiled columns. Hyprland only starts a border resize when the cursor
    -- is inside the extended box AND *outside* the window's real box:
    --
    --   const CBox grab = {real.x - BORDER_GRAB_AREA, ...};
    --   if (grab.containsPoint(mouse) && !real.containsPoint(mouse)) ...
    --     -- InputManager.cpp, onMouseButton
    --
    -- so the area only extends OUTWARD. Between adjacent columns the only
    -- space outside both windows is the gaps_in gap (4px here); a few px
    -- further and you are already inside the neighbour's real box, which
    -- disqualifies the resize no matter how large this value is. Raising
    -- it only widens grabbing at screen edges and around floating
    -- windows. The column seam is therefore owned entirely by
    -- features/dms/plugins/column-seam-drag, which is also the only way
    -- the S Pen can resize at all.
    extend_border_grab_area = 15,
    hover_icon_on_border = true,
  },

  -- GAPS, BORDER AND ROUNDING ARE THIS FEATURE'S, and a themed shell must
  -- not be allowed to set them. Stated here because DMS makes the offer:
  -- its Hyprland theming writes two Lua snippets, each its own hl.config
  -- call -- colors.lua (general.col.*, group.col.*) and layout.lua
  -- (gaps_in/gaps_out/border_size/decoration.rounding).
  --
  -- Colours are safe to hand over, and features/dms does exactly that.
  -- layout.lua is not: it sets border_size = 2, and border_size is not
  -- cosmetic here. The touchscreen workspace-swipe activation strip is
  -- (gaps_out + border_size) / screen_height, so a shell nudging the
  -- border silently widens the strip that steals edge touches. The values
  -- above stay static for that reason.

  input = {
    -- Niri's touchpad block explicitly enables natural-scroll; Hyprland
    -- defaults to non-natural (i.e. inverted relative to what niri was doing).
    touchpad = { natural_scroll = true },

    -- The SAME setting for plain pointers, so an external trackpad scrolls
    -- the same way as the built-in one.
    --
    -- touchpad.natural_scroll only reaches devices libinput classes as
    -- touchpads. The X-Folding RGB bluetooth keyboard/trackpad is not one:
    -- its evdev node advertises REL_X/REL_Y/REL_WHEEL/REL_HWHEEL and NO
    -- ABS_MT_* axes, i.e. the firmware turns its own two-finger swipe into
    -- literal wheel clicks and hands those over. libinput therefore sees a
    -- mouse with a wheel, that obeys input:natural_scroll (default false),
    -- and it scrolled opposite to the built-in touchpad.
    --
    -- Global rather than a `device` section: a per-device rule keyed on
    -- "x-folding-rgb-1" did not take (hyprctl reported no such option), and
    -- the name carries a connection-order suffix that is not worth relying
    -- on. The cost is that a conventional external MOUSE would also get
    -- natural scrolling; flip this to a device rule if that ever matters.
    --
    -- Same reason >2-finger gestures do nothing on that trackpad: with no
    -- multitouch axes libinput cannot synthesise them. Firmware-side, not
    -- configurable here.
    --
    -- Off when features/x-folding-trackpad is enabled: its filter does the
    -- inversion at the device, where it can tell a pinch (Ctrl + wheel)
    -- from a scroll. Inverting here as well would flip the wheel back.
    natural_scroll = nix.naturalScroll,

    -- With a special workspace shown, the regular workspace under it takes no input
    -- by default -- and the side dock (features/sidedock) is the `dock` special
    -- workspace, so an open dock made every ordinary window untouchable. This lets
    -- input through while the special workspace holds only floating windows, which
    -- dock cards and scratchboard windows are.
    special_fallthrough = true,
  },

  -- Ask 1, root cause (verified against 0.56.0 source, not guessed):
  -- Super+H/L (movefocus l/r) direction-queries "is there a window to
  -- my left/right?" -- a maximized window fills the screen, so the
  -- query finds nothing and the dispatcher silently no-ops. That's
  -- binds:movefocus_cycles_fullscreen (default false); enabling it
  -- makes movefocus cycle through fullscreen/maximized windows instead
  -- of finding no neighbor. src/config/shared/actions/ConfigActions.cpp,
  -- Actions::moveFocus: the window-to-change-to is only computed via
  -- the fullscreen-aware cycle query when this is true.
  --
  -- Super+J/K (workspace e∓1) and the touchscreen swipe (lisgd, the
  -- SAME dispatcher) were also reported dead on a maximized window,
  -- but that is NOT this setting's doing: the whole changeWorkspace
  -- chain (resolveWorkspaceForChange -> Actions::changeWorkspace ->
  -- CMonitor::changeWorkspace) has no fullscreen/maximize gate
  -- anywhere in 0.56.0 -- the switch and refocus proceed regardless of
  -- the outgoing window's state. Two things have since removed the
  -- likely real causes without touching workspace code at all: the
  -- lisgd commands were legacy-syntax and silently failing under the
  -- Lua config (fixed), and emacs -- the window those reports were
  -- made against -- no longer opens in a fullscreen state at all (see
  -- the scrolling_width rule below, replacing `maximize`). Recheck
  -- before assuming a Hyprland-level bug remains here.
  binds = { movefocus_cycles_fullscreen = true },

  -- 3-finger swipe drags/moves the focused window around; 4-finger
  -- swipe switches workspaces. Vertical to match niri's
  -- vertical-workspace model (workspaces animation style below must
  -- also be "slidevert" -- the swipe's up/down vs left/right behavior
  -- is derived from the animation style, not just this setting).
  --
  -- Hyprland's only touchscreen gesture: a single-finger swipe from the
  -- screen EDGE, switching workspaces. Complements the lisgd daemon
  -- (features/touch-gestures) rather than replacing it -- that handles
  -- multi-finger swipes anywhere on the panel.
  --
  -- The activation strip is (gaps_out + border_size) / screen_height,
  -- so with gaps_out = 4 and border_size = 0 it is four pixels. Enabled
  -- because it costs nothing and is occasionally hit by
  -- accident-turned-habit, but it is not the mechanism to rely on.
  -- Widening it means widening the gaps, which is not worth it.
  --
  -- The axis follows the workspaces animation style, not this setting:
  -- "slidevert" below makes it top/bottom edges, matching the
  -- touchpad's 4-finger vertical gesture.
  gestures = {
    workspace_swipe_touch = true,
    workspace_swipe_touch_invert = false,
  },

  -- NEITHER general.col.* NOR group.col.* is set here, deliberately.
  -- A shell with live theming writes them at runtime (DMS emits a
  -- colors.lua setting both in a single hl.config call, and its feature
  -- requires that file), so a static value here would only race it. With
  -- no shell selected, Hyprland's own defaults apply -- which is the
  -- correct outcome, not a gap.

  decoration = {
    rounding = 16,
    -- Dim behind a shown special workspace -- the scratchpad's tint, so you can tell it
    -- is up. The side dock is a special workspace too and must not darken the screen:
    -- Hyprland captures this value when a special workspace OPENS, so dock.sh sets it to
    -- 0 for the instant it opens the dock workspace and restores it right after.
    -- (Changing it from a workspace.special_active handler does not work: the event
    -- fires after that capture.)
    dim_special = 0.2,
    -- Glassmorphism: true backdrop blur behind translucent surfaces.
    -- Compositor-side half only. Blur applies to translucent WINDOWS
    -- automatically, but a layer surface has to opt in with a
    -- layer_rule, so a shell that wants frosted panels contributes that
    -- rule (and its own alpha) from its own feature.
    blur = {
      enabled = true,
      size = 8,
      passes = 3,
      vibrancy = 0.17,
      ignore_opacity = true,
      popups = true,
      -- Frost texture: over dark/flat backdrops (e.g. the wallpaper
      -- strip behind the bar's exclusive zone -- windows never go
      -- under it), plain blur is invisible. Noise + slight brightness
      -- lift make the glass read as glass regardless of what's behind
      -- it.
      noise = 0.02,
      brightness = 1.1,
      contrast = 1.0,
    },
  },

  -- Native scrolling layout (Hyprland >=0.55, src/layout/algorithm/tiled/scrolling)
  -- -- niri-like columns, no plugin needed. column_width matches niri's
  -- layout.default-column-width.proportion = 0.5 from features/niri/home.nix.
  scrolling = {
    column_width = 0.5,
    fullscreen_on_one_column = true,
    follow_focus = true,
  },

  -- animations.enabled is a real scalar hyprlang value, so it belongs
  -- here; the actual curve/speed data does NOT (see the hl.animation
  -- calls below for why).
  animations = { enabled = true },

  -- Wake the panel on any input. SUPER + SHIFT + P (dpmsOff in home.nix)
  -- blanks it without suspending -- the machine keeps running, so a
  -- build or a download survives -- and nothing else here ever turns
  -- it back on: DMS's idle timeouts are all 0 (never blank, never
  -- suspend) and the dpms dispatcher is one-way. These two are the
  -- way back. dpmsOff flips them off for the length of its grace
  -- window and restores them to the values below, so this is the
  -- resting state, not a one-shot. Note the waking event is still
  -- delivered to the focused surface: a stray key can type into it.
  misc = {
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },

  -- XWayland surfaces on this 1.5-scaled panel get upscaled by the
  -- compositor and look pixelated (first seen on galaxy-buds-client,
  -- an Avalonia/X11 app). force_zero_scaling makes XWayland render at
  -- scale 1 -- crisp, but each X11 app is then responsible for its own
  -- DPI scaling, which for Avalonia the AVALONIA_GLOBAL_SCALE_FACTOR
  -- env below provides. Other-toolkit X11 apps that don't self-scale
  -- will render small until given their own toolkit's scale env
  -- (GDK_SCALE etc.) -- deliberate trade: crisp-but-small beats
  -- blurry, and this host runs almost everything native Wayland.
  xwayland = { force_zero_scaling = true },
})

-- Touchpad multi-finger gestures. hl.gesture({fingers, direction, action}) --
-- direction values verified against TrackpadGestures.cpp's dirForString
-- ("swipe" for the free-drag verb, "vertical"/"horizontal" for axis-locked
-- ones -- NOT the legacy "3, swipe, move" string form, which Lua mode doesn't
-- parse at all).
--
-- 3-finger free drag/move of the focused window. (On a side-dock card the
-- patched move gesture swipes that card and cycles the pile -- features/sidedock.)
hl.gesture({ fingers = 3, direction = "swipe", action = "move" })
-- scroll_move (snake_case -- verified against source, NOT the legacy
-- dispatcher's "scrollMove" spelling, which errors here:
-- "hl.gesture: unknown action \"scrollMove\""): purpose-built gesture
-- for the scrolling layout's tape -- live momentum + snap-to-column
-- (gestures:scrolling:* defaults handle it).
--
-- The 4-finger VERTICAL swipe is further down, next to Mod+J/K: it runs
-- HyprFocusOrWorkspace (walk the column, then change workspace), which needs
-- a Lua function action rather than one of the fixed string actions.
hl.gesture({ fingers = 4, direction = "horizontal", action = "scroll_move" })


-- Cursor, set here because no shell reliably sets it for Hyprland: DMS's
-- cursorSettings plumbing is niri-only (cursorSettings.niri.hideWhenTyping),
-- so Hyprland would otherwise fall back to its own built-in hyprcursor
-- theme. Set both XCURSOR_* (X/Wayland apps) and HYPRCURSOR_*
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
-- qt6ct is installed and a matugen-driven shell generates its palette
-- (DMS writes ~/.config/qt6ct -> DankMatugen.colors) -- this activates
-- it, and is harmless with no such shell: qt6ct then simply uses
-- whatever palette is on disk.
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
hl.env("AVALONIA_GLOBAL_SCALE_FACTOR", nix.primaryOutputScale)

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
-- Special workspaces (the side dock, the scratchpad) inherit that full-screen vertical
-- slide, which read as too much on top of the dock cards' own slide-in. Fade instead.
hl.animation({ leaf = "specialWorkspace", enabled = true, speed = 3, bezier = "default", style = "fade" })

-- Auto-scale differs between compositors (Hyprland picked 2.0 for this
-- 2880x1800 panel; niri's own auto heuristic apparently picked something
-- smaller, hence text/buttons looking oversized after switching). Pin
-- explicitly so it doesn't depend on Hyprland's auto-detection. Output name
-- and scale both come from the host -- see my.desktop.primaryOutput.
--
-- Rotation survives a reload. A rebuild rewrites this file and Hyprland
-- re-runs it, which used to drop the output back to transform 0 --
-- the rotation source only emits on an orientation CHANGE, so nothing
-- put it back. The rotation shim (rotation.nix) records every transform
-- it applies under $XDG_STATE_HOME, and this re-applies the same four
-- pieces the shim sets: output, touch, pen and the scrolling axis.
-- State dir, so it also outlives a logout or reboot. If the machine is
-- held differently by then, the rotation source corrects it: the
-- vehicleMotionCues patch makes it read the real transform at start
-- instead of assuming 0.
local rotation = nil
do
  local state = os.getenv("XDG_STATE_HOME")
  if not state or state == "" then state = (os.getenv("HOME") or "") .. "/.local/state" end
  local f = io.open(state .. "/hypr/transform-" .. nix.primaryOutput)
  if f then
    local t = tonumber(f:read("l"))
    f:close()
    if t and t >= 1 and t <= 3 then rotation = t end
  end
end
hl.monitor({
  output = nix.primaryOutput,
  mode = "preferred",
  position = "auto",
  scale = nix.primaryOutputScale,
  transform = rotation or 0,
})
if rotation then
  hl.config({ input = { touchdevice = { transform = rotation }, tablet = { transform = rotation } } })
  -- Same transform -> axis mapping as the shim.
  hl.config({ scrolling = { direction = ({ "down", "left", "up" })[rotation] } })
end

-- iio-hyprland: reads iio-sensor-proxy orientation over D-Bus, rotates the
-- eDP-1 output and touch input transform automatically (accel_3d + hinge
-- sensors confirmed present via /sys/bus/iio/devices; enabled in hardware.nix).
-- NOTHING ELSE IS SPAWNED HERE, and a shell least of all: its feature
-- starts it as a systemd user service off graphical-session.target,
-- which uwsm activates. An exec-once copy alongside that produced a
-- second, unmanaged instance -- observed as two bars, one
-- hyprland-parented. Same reasoning as the niri side's
-- spawn-at-startup comment.
--
-- INSIDE hl.on("hyprland.start"), NEVER at top level: a top-level
-- hl.exec_cmd runs on EVERY config reload (the whole Lua script
-- re-executes; hyprlang's exec-once semantics do not exist here), and
-- the rotation shim's transform-0 path calls `hyprctl reload` -- each
-- landscape rotation spawned another instance, every instance reacted
-- to every subsequent rotation, and the loop compounded to 4068 live
-- processes and a load average of 125 before it was caught. The
-- start event fires once per compositor lifetime; reloads re-register
-- this handler but never re-fire it (ConfigManager clears and
-- re-registers event handlers on reload; the event itself is
-- startup-only -- same mechanism Unstraightened relies on for its
-- own systemd activation block). The wrapper also carries a flock
-- singleton as defense in depth.
-- Only when my.desktop.autorotate is "iio"; another rotation source
-- (iio-niri, vehicleMotionCues) must not race it for the sensor.
hl.on("hyprland.start", function()
  if nix.autorotate == "iio" then hl.exec_cmd("iio-hyprland " .. nix.primaryOutput) end
end)

-- Emacs opens as a FULL-WIDTH COLUMN, not maximized. `maximize` is a
-- fullscreen STATE: it renders over the reserved area, drops gaps and
-- corner rounding, and has to be cleared before any colresize can be
-- seen (which is exactly why Mod+D "didn't shrink" emacs). scrolling_width
-- is the column-width equivalent of `layoutmsg colresize 1` and applies
-- at window-open time -- the scrolling layout reads it in newTarget and
-- feeds it to the new column (ScrollingAlgorithm.cpp: add(width), where
-- the value is a fraction of the tape in the same units as
-- scrolling.column_width, so 1.0 = full width). Result: same footprint,
-- but a normal tiled window -- decorations intact, Mod+D toggles it
-- straight back to 0.5 with no state to clear first.
hl.window_rule({ match = { class = "^(emacs)$" }, scrolling_width = 1.0 })
hl.window_rule({ match = { class = "^(org.gnu.emacs)$" }, scrolling_width = 1.0 })
-- Matplotlib floating
hl.window_rule({ match = { class = "^(Matplotlib)$" }, float = true })
-- KakaoTalk: EVERY window floats, not just the first. Wine gives the
-- contact list, each chat room and every dialog the same X11 WM_CLASS
-- (kakaotalk.exe, via XWayland), so one class rule covers all of them --
-- which is the point, since tiling a pile of small chat windows in the
-- scrolling layout is unusable. The dot is left unescaped to match the
-- org.gnu.emacs rules above; it matches a literal dot regardless.
hl.window_rule({ match = { class = "^(kakaotalk.exe)$" }, float = true })
-- Waydroid size lock
hl.window_rule({ match = { class = "^(Waydroid)$" }, scrolling_width = 1.0 })
-- ...and scale-to-fit. Waydroid's Android display has a fixed size and never
-- follows the window's, so any other size -- a narrower column, a side-dock
-- card, PiP -- would crop it. The `fit` tag makes the patched renderer
-- (trapezoid.patch, CWindow::fitTransform) draw it scaled down to the window
-- box instead, aspect kept, with input mapped back. Dock and PiP cards are
-- fitted anyway; on stock Hyprland the tag is inert.
hl.window_rule({ match = { class = "^(Waydroid)$" }, tag = "+fit" })
-- Glassmorphism: translucent KDE apps; backdrop blur applies to
-- translucent windows automatically (decoration.blur). kdeconnect
-- covers all its windows (.app, .sms, -indicator, ...).
hl.window_rule({ match = { class = "^(org\\.kde\\.dolphin)$" }, opacity = "0.65 0.65" })
hl.window_rule({ match = { class = "^(org\\.kde\\.kdeconnect.*)$" }, opacity = "0.65 0.65" })
-- Claude Desktop deliberately has NO opacity rule. It carries its own
-- alpha in the surface instead: features/claude-desktop/blacken.py makes
-- the window transparent and paints one rgba(0,0,0,.65) base, exactly
-- like kitty's `background #000000` + `background_opacity 0.65`.
--
-- A compositor opacity rule multiplies EVERY pixel, so images, the PDF
-- thumbnail and the message bubbles all went translucent too, and the
-- scroll-fade gradient stopped working -- its opaque end was no longer
-- opaque, so scrolled text bled through and the boundary read as a hard
-- step. Per-surface alpha fixes both: glass background, solid content.
-- Blur still applies; decoration.blur blurs behind translucent PIXELS,
-- which is what the window now has.
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

-- Application spawns. Anything that toggles a SHELL surface -- launcher,
-- notifications, clipboard, power menu, lock -- is contributed by
-- whichever feature implements that shell, not bound here.
hl.bind(mod .. " + Return", hl.dsp.exec_cmd("kitty"))
hl.bind(mod .. " + W", hl.dsp.exec_cmd("firefox"))
hl.bind(mod .. " + E", hl.dsp.exec_cmd("emacsclient -c"))
-- Compositor-level IME toggle, same logic as niri.nix's Hangul bind.
hl.bind("Hangul", hl.dsp.exec_cmd(nix.hangulToggle))

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
  -- A window in fullscreen STATE (w.fullscreen: 0 none, 1 maximized,
  -- 2 fullscreen -- the FSMODE enum) renders full-screen regardless
  -- of its column width, so colresize alone visibly does nothing.
  -- Emacs is the live case: its `maximize on` windowrule opens it in
  -- state 1, and the first Mod+D "didn't shrink" because it resized
  -- the column underneath the state. Clear the state instead; the
  -- column width it returns to is whatever it had.
  if w.fullscreen ~= 0 then
    hl.dispatch(hl.dsp.window.fullscreen({
      mode = (w.fullscreen == 1) and "maximized" or "fullscreen",
      action = "unset",
    }))
    return
  end
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
-- end-4's Mod+P is "pin". Here Mod+P is the side dock's picture-in-picture
-- (features/sidedock, a pin plus a keystoned mini-card), so plain pin goes
-- on Mod+Alt+P.
hl.bind(mod .. " + ALT + P", hl.dsp.window.pin())
-- niri's Mod+Shift+V (switch focus between floating/tiling) has no
-- direct hyprland dispatcher; `togglegroup` is a different concept
-- (window grouping), so it's dropped rather than mis-mapped.

-- niri's Mod+R (switch-preset-column-width) -> scrolling layout's
-- colresize +conf, which cycles through scrolling:explicit_column_widths.
hl.bind(mod .. " + R", hl.dsp.layout("colresize +conf"))

-- end-4/dots-hyprland's Super+;/' ("adjust split ratio"). end-4 runs
-- dwindle; on this scrolling layout the same feel is a CONSERVED seam
-- move -- the focused column shrinks/grows and its visible neighbour does
-- the opposite, total constant, like a tiling divider. columnResizeSplit
-- resizes both columns by address (colresize alone only touches the
-- focused one and lets the tape absorb the difference). Repeating so a
-- held key keeps moving the seam, as end-4's do.
-- Super + left-drag moves the focused window: the pointer equivalent of
-- the 3-finger touchpad swipe (gesture `action = "move"` above).
-- `drag = true` is the bindm equivalent in the Lua API, and the
-- dispatcher is window.drag -- window.move needs a direction and rejects
-- an empty call, so it cannot serve as the mouse-drag verb.
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { drag = true })

hl.bind(mod .. " + Semicolon", hl.dsp.exec_cmd(nix.columnResizeSplit .. " -0.1"), { repeating = true })
hl.bind(mod .. " + Apostrophe", hl.dsp.exec_cmd(nix.columnResizeSplit .. " 0.1"), { repeating = true })

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
--
-- `focus l/r/u/d` is NOT screen-relative. It means previous/next column
-- (l/r) and previous/next window in the column (u/d) -- swapped to u/d
-- and l/r when the tape runs vertically -- and the rotation shim turns
-- the tape with the screen (rotation.nix: 180 deg -> "left", 90 ->
-- "down", 270 -> "up"). At 180 deg the next column sits on the screen's
-- LEFT, so L went left. Hyprland's own movewindow already translates
-- (ScrollingAlgorithm.cpp, moveTargetTo's rotateDir); layoutmsg focus
-- does not, so this does the same translation. Worked through that
-- table, only two cases differ from the literal key: "left" swaps l/r,
-- "up" swaps u/d. "down" needs nothing -- l/r are then within-column
-- steps, which run left to right.
function HyprLayoutFocusArg(dir)
  local tape = hl.get_config("scrolling.direction")
  if tape == "left" and (dir == "l" or dir == "r") then
    return dir == "l" and "r" or "l"
  elseif tape == "up" and (dir == "u" or dir == "d") then
    return dir == "u" and "d" or "u"
  end
  return dir
end
hl.bind(mod .. " + H", function() hl.dispatch(hl.dsp.layout("focus " .. HyprLayoutFocusArg("l"))) end)
hl.bind(mod .. " + L", function() hl.dispatch(hl.dsp.layout("focus " .. HyprLayoutFocusArg("r"))) end)
-- Workspace cycle among EXISTING workspaces ("e±1"), same string
-- syntax as the legacy `workspace, e-1` dispatcher -- hl.dsp.focus's
-- workspace-selector overload hands it to the identical parser.
-- RELATIVE, NOT e-RELATIVE. These were "e-1"/"e+1", which walk only
-- workspaces that already EXIST -- so from workspace 10 with nothing
-- above it, e+1 wrapped back to 1 (measured, not assumed). That made
-- every page past the first unreachable, and paging is the whole point
-- of a shell's workspace strip.
--
-- Plain "+1"/"-1" step into empty workspaces, creating them on demand:
-- 10 -> 11 -> 12, which rolls the page over as intended. "-1" clamps at
-- workspace 1 rather than running negative, so the low end needs no
-- special case.
--[[
  Vertical focus that falls through to a workspace switch at the end of
  the column. ONE implementation for all three input paths -- Mod+J/K,
  the touchpad's vertical swipe, and the touchscreen's (which calls this
  same global through `hyprctl eval`, see features/touch-gestures) -- so
  they cannot drift. They used to: the keys and the touchscreen stepped
  workspaces with focus{workspace="+1"/"-1"} (creating empty ones on
  demand) while the touchpad used the built-in `workspace` gesture, which
  only walks workspaces that already EXIST. A blank workspace therefore
  behaved differently depending on how you asked for it.

  IN-PROCESS, deliberately. The first version shelled out to a Python
  script, which meant an interpreter start plus two `hyprctl` round-trips
  per keypress -- a noticeable lag on a keybind. hl.bind takes a Lua
  function directly, so this runs inside the compositor with no spawn.

  The end of a column is found by POSITION, not by "focus didn't move":
  the scrolling layout WRAPS to the other end of the column when it runs
  out (ScrollingAlgorithm.cpp falls back to targetDatas.front()/back()
  unless general:no_focus_fallback), so a no-move signal is not readable.
]]
function HyprFocusOrWorkspace(dir)
  local down = dir == "down"
  local function switchWorkspace()
    hl.dispatch(hl.dsp.focus({ workspace = down and "+1" or "-1" }))
  end

  local active = hl.get_active_window()
  -- Nothing focused (blank workspace) or floating: no column to walk.
  if not active or active.floating or not active.workspace then
    switchWorkspace()
    return
  end

  local wins = hl.get_workspace_windows(active.workspace.id)
  if not wins then
    switchWorkspace()
    return
  end

  -- Tape running vertically (portrait): up/down is between columns,
  -- which are stacked rows now, so the edge is simply "no tiled window
  -- further that way" -- a same-x test would miss a row split
  -- differently from this one.
  local tape = hl.get_config("scrolling.direction")
  if tape == "down" or tape == "up" then
    local beyond = false
    for _, w in ipairs(wins) do
      if w.mapped and not w.hidden and not w.floating and w.address ~= active.address
          and ((down and w.at.y > active.at.y + 4) or (not down and w.at.y < active.at.y - 4)) then
        beyond = true
      end
    end
    if beyond then
      hl.dispatch(hl.dsp.layout("focus " .. HyprLayoutFocusArg(down and "d" or "u")))
    else
      switchWorkspace()
    end
    return
  end

  -- The focused window's column: tiled windows sharing its x, top down.
  local function colX(w) return math.floor(w.at.x / 8 + 0.5) * 8 end
  local ax, col = colX(active), {}
  for _, w in ipairs(wins) do
    if w.mapped and not w.hidden and not w.floating and colX(w) == ax then
      col[#col + 1] = w
    end
  end
  table.sort(col, function(a, b) return a.at.y < b.at.y end)

  local idx
  for i, w in ipairs(col) do
    if w.address == active.address then idx = i end
  end
  if not idx then
    switchWorkspace()
    return
  end

  if (down and idx == #col) or (not down and idx == 1) then
    switchWorkspace()
  else
    hl.dispatch(hl.dsp.layout("focus " .. HyprLayoutFocusArg(down and "d" or "u")))
  end
end

-- The Page keys below stay pure workspace paging, which is what they are for.
hl.bind(mod .. " + K", function() HyprFocusOrWorkspace("up") end, { repeating = true })
hl.bind(mod .. " + J", function() HyprFocusOrWorkspace("down") end, { repeating = true })

-- The touchpad's 4-finger vertical swipe, same function as J/K. Declared
-- as a function rather than a string action because only the Lua form
-- takes a FUNCTION as the action; a plain function is registered as the
-- gesture's END callback (LuaFunctionGesture's legacy-end-only ctor), so
-- it fires once per completed swipe rather than continuously -- discrete,
-- like the keybind. That does give up the built-in gesture's live
-- follow-the-finger animation, which is the price of the three paths
-- behaving identically.
--
-- Swipe UP maps to "down" (focus down the column, then workspace +1),
-- matching both Mod+J and the touchscreen's DU spec in
-- features/touch-gestures.
hl.gesture({ fingers = 4, direction = "up",
  action = function() HyprFocusOrWorkspace("down") end })
hl.gesture({ fingers = 4, direction = "down",
  action = function() HyprFocusOrWorkspace("up") end })
hl.bind(mod .. " + Page_Down", hl.dsp.focus({ workspace = "-1" }))
hl.bind(mod .. " + Page_Up", hl.dsp.focus({ workspace = "+1" }))
hl.bind(mod .. " + CTRL + U", hl.dsp.window.move({ workspace = "-1", follow = true }))
hl.bind(mod .. " + CTRL + I", hl.dsp.window.move({ workspace = "+1", follow = true }))

-- Scratchboard: a special workspace overlaid on the current one (end-4 has
-- it on Mod+S, which is the side dock here). Mod+C shows/hides it;
-- Mod+Ctrl+C sends the focused window there without following, or, for a
-- window already on it, brings it back to the workspace underneath.
-- Global, so features/sidedock can wrap it (Mod+Ctrl+C on a dock card undocks it).
hl.bind(mod .. " + C", hl.dsp.workspace.toggle_special("scratch"))

function HyprScratchToggle()
  local w = hl.get_active_window()
  if not w then return end
  if w.workspace and w.workspace.name == "special:scratch" then
    local ws = w.monitor and w.monitor.active_workspace
    if ws then hl.dispatch(hl.dsp.window.move({ workspace = tostring(ws.id), follow = false })) end
  else
    hl.dispatch(hl.dsp.window.move({ workspace = "special:scratch", follow = false }))
  end
end
hl.bind(mod .. " + CTRL + C", function() HyprScratchToggle() end)

-- Move window (direction)
hl.bind(mod .. " + CTRL + left", hl.dsp.window.move({ direction = "left" }))
hl.bind(mod .. " + CTRL + down", hl.dsp.window.move({ direction = "down" }))
hl.bind(mod .. " + CTRL + up", hl.dsp.window.move({ direction = "up" }))
hl.bind(mod .. " + CTRL + right", hl.dsp.window.move({ direction = "right" }))
hl.bind(mod .. " + CTRL + H", hl.dsp.window.move({ direction = "left" }))
hl.bind(mod .. " + CTRL + J", hl.dsp.window.move({ direction = "down" }))
hl.bind(mod .. " + CTRL + K", hl.dsp.window.move({ direction = "up" }))
hl.bind(mod .. " + CTRL + L", hl.dsp.window.move({ direction = "right" }))
hl.bind(mod .. " + CTRL + Page_Down", hl.dsp.window.move({ workspace = "-1", follow = true }))
hl.bind(mod .. " + CTRL + Page_Up", hl.dsp.window.move({ workspace = "+1", follow = true }))

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

-- Workspaces: PAGE-RELATIVE, not absolute.
--
-- Super+N goes to slot N of the group of ten containing the focused
-- workspace, so on workspace 15 Super+1 means 11. The digits keep meaning
-- "first slot of what I am looking at" instead of an id you have to
-- remember. A shell drawing a workspace strip derives its page the same
-- way, from the live focused workspace, so the two cannot drift -- see
-- features/dms/plugins/workspaces for the one that does.
--
-- The persistent workspace_rule calls that used to be here are GONE. They
-- existed to force the DankBar switcher to render a fixed 1-9; the plugin
-- draws ten slots whether or not the workspaces exist, so keeping them
-- would only pin page 0 into existence while every other page stayed
-- ephemeral -- an asymmetry with no upside.
for i = 1, 9 do
  hl.bind(mod .. " + " .. tostring(i), hl.dsp.exec_cmd(nix.wsSlot .. " " .. tostring(i)))
  hl.bind(mod .. " + CTRL + " .. tostring(i), hl.dsp.exec_cmd(nix.wsSlot .. " " .. tostring(i) .. " move"))
end
-- 0 is the tenth slot, keeping the row of digits contiguous.
hl.bind(mod .. " + 0", hl.dsp.exec_cmd(nix.wsSlot .. " 10"))
hl.bind(mod .. " + CTRL + 0", hl.dsp.exec_cmd(nix.wsSlot .. " 10 move"))

hl.bind(mod .. " + SHIFT + E", hl.dsp.exit())
-- --clipboard-only skips writing a file at all (hyprshot otherwise saves
-- AND copies); --silent matches grimblast's old no-notification default.
-- Region snip via the DMS in-shell overlay (features/dms/plugins/screen-snip),
-- which the S Pen can drive; slurp -- what hyprshot wraps -- ignores tablet
-- input, so the pen cannot drag its selection. hyprshot stays as the
-- fallback for when the shell is not running. CTRL/ALT+Print stay on
-- hyprshot: output and window shots need no pen drag.
hl.bind("Print", hl.dsp.exec_cmd("dms ipc call screenSnip region 2>/dev/null || hyprshot -m region --clipboard-only --silent"))
hl.bind("CTRL + Print", hl.dsp.exec_cmd("hyprshot -m output --clipboard-only --silent"))
hl.bind("ALT + Print", hl.dsp.exec_cmd("hyprshot -m window -m active --clipboard-only --silent"))
-- Blank the panel, stay awake, wake on the next input: the grace
-- window in the script is what keeps this chord's own key releases
-- from waking it immediately (see dpmsOff in home.nix).
hl.bind(mod .. " + SHIFT + P", hl.dsp.exec_cmd(nix.dpmsOff))
