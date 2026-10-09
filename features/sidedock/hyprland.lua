-- features/sidedock: Hyprland half of the side dock (from sihooleebd/nixos 0a7686c).
--
-- Light apps live on a right-edge panel as a CASCADE STACK, on their own `dock` special
-- workspace, so DMS's workspace strip never lists them. Every placement in
-- dock.sh is by window address, never by focusing, so main-area windows are
-- left alone. Upstream's wallpaper repaint and opendisplay hooks are left out;
-- the dock is driven by the keys below and the 3-finger swipe (the patched
-- move gesture, configured at the bottom).

local nix = require("nix.sidedock")
local mod = nix.mod
local dock = nix.dock

-- One auto-route rule per docked app. The window is born a card: FLOATING, on the dock
-- workspace (silently -- it does not switch you there), card-sized and parked just past
-- the right edge, so its first frame is off-screen. With the dynamic dock tag added in
-- window.open_early below it is already a trapezoid, and `adopt` (window.open) then just
-- slides it in from the side -- instead of the app appearing as a normal window
-- somewhere and visibly migrating into the dock. dock.sh is the authority on geometry:
-- adopt re-sizes, size-locks and places it from the live, logical geometry.
--
-- The rule does NOT tag the window 'dock': a rule tag reads as "dock*" and cannot be
-- removed by the tag dispatcher, so an auto-routed window could never be undocked.
-- The window.open handler recognises it by CLASS and dock.sh applies a dynamic tag.
-- Border off (drawn at the flat box, not warped); blur and shadow stay on, since the
-- keystone patch warps both to the trapezoid.
local dockClasses = {}
for _, c in ipairs(nix.classes) do
  dockClasses[c] = true
  hl.window_rule({ match = { class = "^(" .. c .. ")$" }, workspace = "special:dock silent", float = true,
    size = "33% 88%", move = "100% 8%", opacity = "1.0 1.0", border_size = 0, rounding = 0, no_initial_focus = true })
end
-- The same birth for any other window that opens ON the dock workspace while a card has
-- focus: it joins the pile (window.open below). Modal dialogs are left alone. Enabled
-- only while a card has focus -- see syncOpenRules() further down.
-- Never fcitx5's own X11 popup: switching the input method in an XWayland card (wine
-- KakaoTalk) maps a "Fcitx5 Input Window" -- the IM indicator -- on the dock workspace.
-- It was born a card: sized 33%x88% (a blank card), brought to the front, and on its
-- close a moment later `orphan` focused the card behind it, so the card you were typing
-- in lost the keyboard. Matched by title: its WM_CLASS reads "fcitx\0fcit".
local imePopupTitle = "Fcitx5 Input Window"
-- Kept out of the pile it is still a managed window, so on its own it would TILE -- over
-- the whole dock workspace, a big blank box around a few characters. Float it at the size
-- it asks for, and never focus it, wherever it opens.
hl.window_rule({ match = { title = "^(" .. imePopupTitle .. ")$" }, float = true,
  no_focus = true, no_initial_focus = true, border_size = 0, no_shadow = true })
local dockBirth = hl.window_rule({ match = { workspace = "special:dock", modal = false,
  title = "negative:^(" .. imePopupTitle .. ")$" }, float = true,
  size = "33% 88%", move = "100% 8%", border_size = 0, rounding = 0, enabled = false })

hl.bind(mod .. " + " .. nix.keys.toggle, hl.dsp.exec_cmd(dock .. " toggle"))
-- The dock as a workspace: send the focused window there, or back out.
hl.bind(mod .. " + " .. nix.keys.dockToggle, hl.dsp.exec_cmd(dock .. " dock-toggle"))
hl.bind(mod .. " + " .. nix.keys.terminal, hl.dsp.exec_cmd("kitty --class " .. nix.termClass))
hl.bind(mod .. " + " .. nix.keys.prev, hl.dsp.exec_cmd(dock .. " prev"))
hl.bind(mod .. " + " .. nix.keys.next, hl.dsp.exec_cmd(dock .. " next"))
-- Picture-in-picture: the focused window becomes a pinned, keystoned mini-card
-- bottom-right (a `pip` tag keeps it out of the pile); again to put it back.
hl.bind(mod .. " + " .. nix.keys.pipToggle, hl.dsp.exec_cmd(dock .. " pip-toggle"))
-- Hide the focused PiP out of the way (it keeps running), or bring back the last
-- hidden one where it was.
hl.bind(mod .. " + " .. nix.keys.pip, hl.dsp.exec_cmd(dock .. " pip-showhide"))

-- Touchscreen equivalents (features/hyprland/touch.lua). dock.sh's verbs act on the
-- focused window, so each first focuses the window under the fingers -- the same verb as
-- the key, aimed by touch.
do
  local Touch = require("feat.touch")
  local function onWindow(g, verb)
    if g.window and g.window.address then
      hl.dispatch(hl.dsp.focus({ window = "address:" .. g.window.address }))
    end
    hl.dispatch(hl.dsp.exec_cmd(dock .. " " .. verb))
  end
  -- three fingers tapped twice: PiP / un-PiP (Super+Ctrl+P)
  Touch.gesture({ fingers = 3, kind = "tap", taps = 2, action = function(g) onWindow(g, "pip-toggle") end })
  -- four fingers held: into / out of the dock (Super+Ctrl+S). A hold, not a double tap:
  -- a double tap makes the single four-finger tap (spotlight, features/dms) wait out
  -- double_tap_gap before it can fire, and spotlight should open at once.
  Touch.gesture({ fingers = 4, kind = "hold", action = function(g) onWindow(g, "dock-toggle") end })
  -- five fingers tapped: hide the PiP under them, or bring back every hidden one (Super+P)
  Touch.gesture({ fingers = 5, kind = "tap", action = function(g) onWindow(g, "pip-showhide") end })

  -- Five-finger swipe away from the dock's edge shows it, toward the edge hides it --
  -- in the panel's PHYSICAL frame, since the dock stays on the physical right edge at
  -- every rotation (logical bottom at 90 deg). Moved here from lisgd (2026-10-08), which
  -- had them as 5,RL / 5,LR at -o 0. The swipe direction the recognizer reports is
  -- logical, so "toward the dock" is looked up from the monitor transform at match time.
  -- priority: rotated, one of these is a logical up/down and must beat the 5-finger
  -- swipe-down close (features/hyprland) -- the dock is what that motion means there.
  local function towardDock()
    local t = 0
    pcall(function()
      local c = hl.get_cursor_pos()
      local m = hl.get_monitor_at({ x = c.x, y = c.y })
      t = (m and m.transform or 0) % 4
    end)
    return ({ [0] = "right", [1] = "down", [2] = "left", [3] = "up" })[t]
  end
  local opposite = { right = "left", left = "right", up = "down", down = "up" }

  -- LIVE: the pile follows the fingers and letting go finishes or springs back
  -- (feat.dockswipe; dock.sh writes the layout cache it reads and `settle`s the end).
  local Live = require("feat.dockswipe").new({
    layout = (os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000") .. "/sidedock.layout",
    settle = function(m) hl.dispatch(hl.dsp.exec_cmd(dock .. " settle " .. m)) end,
    discrete = function(m) if m == "show" then SideDockShow() else SideDockHide() end end,
    monitor = function()
      local r = {}
      pcall(function()
        local c = hl.get_cursor_pos()
        local m = hl.get_monitor_at({ x = c.x, y = c.y })
        r.transform = m.transform or 0
        r.special = m.active_special_workspace and m.active_special_workspace.name or nil
      end)
      return r
    end,
    windows = function()
      local set = {}
      for _, w in ipairs(hl.get_windows()) do set[w.address] = true end
      return set
    end,
    setNoAnim = function(a, on)
      hl.dispatch(hl.dsp.window.set_prop({ prop = "no_anim", value = on and "true" or "unset", window = "address:" .. a }))
    end,
    move = function(a, x, y) hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = "address:" .. a })) end,
    -- as dock.sh's dockws_show: Hyprland captures dim_special when a special workspace
    -- opens, and the global value is the scratchpad's tint
    openDock = function()
      local ok, dim = pcall(hl.get_config, "decoration.dim_special")
      hl.config({ decoration = { dim_special = 0 } })
      hl.dispatch(hl.dsp.workspace.toggle_special("dock"))
      hl.config({ decoration = { dim_special = (ok and tonumber(dim)) or 0 } })
    end,
  })
  for _, m in ipairs({ "show", "hide" }) do
    Touch.gesture({ fingers = 5, kind = "swipe", priority = 50,
      direction = function(d)
        if m == "show" then return d == opposite[towardDock()] end
        return d == towardDock()
      end,
      begin = function(g) Live.begin(m, g) end,
      update = function(g) Live.update(g) end,
      finish = function(g) Live.finish(g) end,
      cancel = function() Live.cancel() end })
  end
end
-- How small a PiP's content is drawn (it lays out for keystone_pip_zoom x its box):
-- Mod+Alt+minus shrinks the content, Mod+Alt+equal enlarges it, like browser zoom.
hl.bind(mod .. " + ALT + minus", hl.dsp.exec_cmd(dock .. " pip-zoom out"))
hl.bind(mod .. " + ALT + equal", hl.dsp.exec_cmd(dock .. " pip-zoom in"))

do
  -- A rule-applied tag reads as "dock*", a dispatcher one as "dock".
  local function isDockWin(w)
    local hit = false
    pcall(function()
      if w and w.tags then
        for _, t in ipairs(w.tags) do if t == "dock" or t == "dock*" then hit = true; break end end
      end
    end)
    return hit
  end

  -- Keep the cascade in sync as dock windows come and go. OPEN is matched by
  -- class (the rule doesn't tag; `adopt` applies the dynamic tag), CLOSE by
  -- the tag, so a window you undocked is correctly left alone.
  -- The dock as a workspace: while a pile card has focus (the pointer is on the
  -- shown dock -- focus follows the mouse), a newly opened window joins the pile
  -- instead of tiling behind it. "Had focus" is judged at the moment the window
  -- opened: if the new window has already taken focus by then, the focus before
  -- it counts. Floating windows -- dialogs, a dock app's own file chooser -- are
  -- left where they open; so is a PiP card, which is not part of the pile.
  local function isPip(w)
    local hit = false
    pcall(function()
      for _, t in ipairs(w.tags) do if t == "pip" or t == "pip*" then hit = true; break end end
    end)
    return hit
  end
  local focusAddr, focusDock, prevFocusDock = nil, false, false

  -- Where a new window opens is decided by window rules, BEFORE it is mapped. Hyprland
  -- puts every new window on the monitor's open special workspace regardless of focus,
  -- so with the dock open but focus on an ordinary window (input falls through to it),
  -- a new app would land on the dock workspace and have to be moved back -- a visible
  -- flicker. So, on every focus change:
  --   card focused       -> dockBirth on: the new window is born a card (joins the pile)
  --   ordinary window    -> a redirect rule for THAT window's workspace on: the new
  --                         window opens there directly, never touching the dock workspace
  -- A rule cannot see focus, hence the toggling. One redirect rule per workspace id,
  -- created on first use and only ever enabled one at a time.
  local redirects = {}
  local function syncOpenRules(w)
    dockBirth:set_enabled(focusDock)
    for _, r in pairs(redirects) do r:set_enabled(false) end
    if not focusDock and w and w.workspace and not w.workspace.special then
      local id = w.workspace.id
      if not redirects[id] then
        redirects[id] = hl.window_rule({ match = { workspace = "special:dock" }, workspace = tostring(id), enabled = false })
      end
      redirects[id]:set_enabled(true)
    end
  end

  hl.on("window.active", function(w)
    local addr = w and w.address or nil
    if addr == focusAddr then return end
    prevFocusDock = focusDock
    focusDock = w ~= nil and isDockWin(w) and not isPip(w)
    focusAddr = addr
    syncOpenRules(w)
  end)

  -- Decide BEFORE the first frame. window.open_early fires before the window is laid
  -- out or drawn, and focus has not moved to it yet, so focusDock is still "a card had
  -- focus". A window joining the pile gets the dynamic dock tag here, so the keystone
  -- warps it from its very first frame (the rules above already float it off-screen).
  -- The IM popup (see dockBirth) is no card and no stray: it floats over the card it
  -- belongs to and closes by itself; moving or focusing it is what broke typing.
  local function isImePopup(w)
    return w.title == imePopupTitle or (w.class or ""):find("^fcitx") ~= nil
  end

  hl.on("window.open_early", function(w)
    if not w or isImePopup(w) then return end
    local onDockWs = w.workspace ~= nil and w.workspace.name == "special:dock"
    if (w.class and dockClasses[w.class]) or (onDockWs and focusDock) then
      hl.dispatch(hl.dsp.window.tag({ tag = "+dock", window = "address:" .. w.address }))
    end
  end)

  hl.on("window.open", function(w)
    if not w or isImePopup(w) then return end
    if isDockWin(w) and not isPip(w) then
      -- born a card (open_early): slide it in from the side and make it the front
      hl.dispatch(hl.dsp.exec_cmd(dock .. " adopt " .. w.address))
    elseif w.workspace and w.workspace.name == "special:dock" then
      -- fallback (e.g. nothing had focus, so no redirect rule was on): opened on the dock
      -- workspace without joining the pile -- dock.sh puts it back on the regular one
      hl.dispatch(hl.dsp.exec_cmd(dock .. " stray " .. w.address))
    end
  end)
  hl.on("window.close", function(w)
    if isDockWin(w) then hl.dispatch(hl.dsp.exec_cmd(dock .. " orphan " .. w.address)) end
  end)
  -- Re-apply the geometry when the monitor layout changes -- rotation, scale,
  -- a plugged display: re-cascades if shown, re-parks at the new edge if hidden.
  hl.on("monitor.layout_changed", function() hl.dispatch(hl.dsp.exec_cmd(dock .. " relayout")) end)

  -- Mod+H / Mod+L walk the pile while a pile card has focus (H = previous, L = next,
  -- as Mod+Alt+left/right); anywhere else they keep features/hyprland's column focus.
  -- Hyprland appends duplicate binds, hence the unbind; this file loads after that one.
  local function onPileCard()
    local w = hl.get_active_window()
    return w ~= nil and isDockWin(w) and not isPip(w)
  end
  for key, step in pairs({ H = { dock = "prev", tape = "l" }, L = { dock = "next", tape = "r" } }) do
    hl.unbind(mod .. " + " .. key)
    hl.bind(mod .. " + " .. key, function()
      if onPileCard() then
        hl.dispatch(hl.dsp.exec_cmd(dock .. " " .. step.dock))
      else
        hl.dispatch(hl.dsp.layout("focus " .. HyprLayoutFocusArg(step.tape)))
      end
    end)
  end

  -- Mod+Ctrl+C on a pile card: sending it to the scratchpad by hand would strand it there
  -- still tagged as a card. Undock it properly instead.
  hl.unbind(mod .. " + CTRL + C")
  hl.bind(mod .. " + CTRL + C", function()
    if onPileCard() then hl.dispatch(hl.dsp.exec_cmd(dock .. " dock-toggle")) else HyprScratchToggle() end
  end)

  -- Touchscreen (features/touch-gestures runs these through `hyprctl eval`): a 5-finger
  -- swipe toward the panel's physical left shows the dock, toward its right hides it
  -- (sidedock/nixos.nix). Show/hide rather than toggle, so a direction always means one
  -- thing; both are no-ops when already in that state (dock.sh's show/hide verbs).
  function SideDockToggle() hl.dispatch(hl.dsp.exec_cmd(dock .. " toggle")) end
  function SideDockShow() hl.dispatch(hl.dsp.exec_cmd(dock .. " show")) end
  function SideDockHide() hl.dispatch(hl.dsp.exec_cmd(dock .. " hide")) end

  -- Click a BACK card to bring it to the front. Back cards refuse focus (dock.sh sets
  -- no_focus, so hovering one with focus-follows-mouse cannot shuffle the pile), so
  -- the click is caught here instead: of the pile cards under the pointer, the one
  -- nearest the front (lowest dockd<N> depth tag) wins; if that is a back card, dock.sh
  -- re-lays the pile with it in front. non_consuming: the click still reaches whatever
  -- window is under it, so every other click behaves exactly as before.
  local function depthOf(w)
    for _, t in ipairs(w.tags or {}) do
      local n = t:match("^dockd(%d+)%*?$")
      if n then return tonumber(n) end
    end
  end
  -- Is point c on the card AS DRAWN? Cards are keystone trapezoids, not their flat boxes:
  -- the front card's box reaches over the back cards' visible edges, so a box test sent
  -- clicks on those edges to the front card. The trapezoid is fixed by keystone_inset /
  -- keystone_shrink, pinned to the dock's PHYSICAL edge -- the window-unit point is mapped
  -- into the canonical "pinned right edge" frame the same way the patch orients the warp
  -- (ksOrientToEdge: transpose at 90, mirror at 180, both at 270). Its edges are straight.
  local function onCard(w, c)
    local u = (c.x - w.at.x) / w.size.x
    local v = (c.y - w.at.y) / w.size.y
    if u < 0 or u > 1 or v < 0 or v > 1 then return false end
    local edge = ((w.monitor and w.monitor.transform) or 0) % 4
    local cu, cv = u, v
    if edge == 1 then cu, cv = v, u
    elseif edge == 2 then cu, cv = 1 - u, v
    elseif edge == 3 then cu, cv = 1 - v, u end
    local inset  = tonumber(hl.get_config("decoration.keystone_inset")) or 0
    local shrink = tonumber(hl.get_config("decoration.keystone_shrink")) or 0
    if cu < inset then return false end
    local t = (inset < 1) and (cu - inset) / (1 - inset) or 1 -- 0 at the far edge, 1 at the pinned one
    local margin = shrink * (1 - t)
    return cv >= margin and cv <= 1 - margin
  end

  -- Bring the back card under point c to the front -- unless a layer surface took the
  -- press: c.layer (touch and pen events carry it: the Hyprland fork's touchscreen-swipes commit) or, for the mouse,
  -- hl.layer_at. The on-screen keyboard's 'o' sits over a back card's edge in
  -- landscape, and tapping it raised the card as well (2026-10-08).
  local function frontAt(c)
    if c.layer then return end
    if hl.layer_at then
      local ok, ls = pcall(hl.layer_at, { x = c.x, y = c.y })
      if ok and ls then return end
    end
    pcall(function()
      local best, bestDepth
      for _, w in ipairs(hl.get_windows()) do
        if isDockWin(w) and not isPip(w) and not w.hidden
           and w.workspace and w.workspace.name == "special:dock" and onCard(w, c) then
          local d = depthOf(w)
          if d and (not bestDepth or d < bestDepth) then best, bestDepth = w, d end
        end
      end
      if best and bestDepth > 0 then
        hl.dispatch(hl.dsp.exec_cmd(dock .. " front " .. best.address))
      end
    end)
  end

  hl.bind("mouse:272", function() frontAt(hl.get_cursor_pos()) end, { non_consuming = true })
  -- A finger or the pen press through the touch/tablet path, not the button one, so the
  -- bind above never sees them; Hyprland fork, keystone lua-touch-pen-events reports both as Lua events with the point.
  -- pcall: a Hyprland without the patch rejects the unknown event names.
  pcall(hl.on, "input.touch.down", function(p) frontAt(p) end)
  pcall(hl.on, "input.tablet.tip", function(p) frontAt(p) end)

  -- Fullscreening a docked card or dragging one out breaks the cascade, so
  -- the existing SUPER+F and SUPER+drag binds (features/hyprland) are
  -- replaced by guarded versions. Hyprland APPENDS duplicate binds, hence
  -- the unbind first; this file loads after features/hyprland's, so the
  -- originals exist. Any query error falls through to the normal action.
  local fullscreen = hl.dsp.window.fullscreen({ mode = "fullscreen" })
  hl.unbind(mod .. " + F")
  hl.bind(mod .. " + F", function()
    if not isDockWin(hl.get_active_window()) then hl.dispatch(fullscreen) end
  end)

  -- Same for the keyboard moves: SUPER+CTRL+H/J/K/L and arrows move a window in
  -- a direction, SUPER+SHIFT+CTRL to another monitor. On a pile card they shoved
  -- the floating card across the screen; the pile's layout is dock.sh's alone. A
  -- PiP (dock-tagged too) keeps them, as it keeps SUPER+drag below.
  local function guardMove(keys, arg)
    local action = hl.dsp.window.move(arg)
    hl.unbind(mod .. " + " .. keys)
    hl.bind(mod .. " + " .. keys, function()
      local w = hl.get_active_window()
      if not (isDockWin(w) and not isPip(w)) then hl.dispatch(action) end
    end)
  end
  for _, m in ipairs({
    { "CTRL + left", { direction = "left" } }, { "CTRL + H", { direction = "left" } },
    { "CTRL + down", { direction = "down" } }, { "CTRL + J", { direction = "down" } },
    { "CTRL + up", { direction = "up" } },     { "CTRL + K", { direction = "up" } },
    { "CTRL + right", { direction = "right" } }, { "CTRL + L", { direction = "right" } },
    { "SHIFT + CTRL + left", { monitor = "l" } }, { "SHIFT + CTRL + H", { monitor = "l" } },
    { "SHIFT + CTRL + down", { monitor = "d" } }, { "SHIFT + CTRL + J", { monitor = "d" } },
    { "SHIFT + CTRL + up", { monitor = "u" } },   { "SHIFT + CTRL + K", { monitor = "u" } },
    { "SHIFT + CTRL + right", { monitor = "r" } }, { "SHIFT + CTRL + L", { monitor = "r" } },
  }) do guardMove(m[1], m[2]) end

  local startDrag = hl.dsp.window.drag()
  hl.unbind(mod .. " + mouse:272")
  hl.bind(mod .. " + mouse:272", function()
    local overDock = false
    pcall(function()
      local c = hl.get_cursor_pos()
      for _, w in ipairs(hl.get_windows()) do
        if isDockWin(w) and not isPip(w) and not w.hidden   -- a PiP may be dragged
           and c.x >= w.at.x and c.x < w.at.x + w.size.x
           and c.y >= w.at.y and c.y < w.at.y + w.size.y then
          overDock = true
          break
        end
      end
    end)
    if not overDock then hl.dispatch(startDrag) end
  end, { drag = true })
end

-- The pile slides as one; give window moves an ease-out without overshoot.
hl.curve("dockslide", { type = "bezier", points = { { 0.16, 1.0 }, { 0.3, 1.0 } } })

hl.animation({ leaf = "windowsMove", enabled = true, speed = 3.5, bezier = "dockslide" })

if nix.keystone then
  -- Two-finger tap a PiP, then pinch it: live zoom, the continuous form of Super+Alt+minus/equal
  -- (dock.sh pip-zoom). keystone_pip_zoom is how many times its box the client is told it
  -- is; spreading the fingers shows the content larger, i.e. a smaller zoom. Same 1..8
  -- range. The PiP under the fingers is nudged on each step so its client is re-told; at
  -- the end every PiP is (the value is global), as pip-zoom does.
  do
    local Touch = require("feat.touch")
    local z0, last = 3, nil
    -- Re-tell the client its size: grow 1 px and shrink back. A floating window resizes
    -- about its centre, and the half pixels round the same way both times, so each
    -- nudge moved it 1 px right -- measured, and over a pinch's dozens of steps the PiP
    -- crept visibly rightward whichever way the fingers went. Put it back where it was.
    local function nudge(addr)
      local at
      for _, w in ipairs(hl.get_windows()) do
        if w.address == addr then at = w.at; break end
      end
      local win = "address:" .. addr
      hl.dispatch(hl.dsp.window.resize({ x = 1, y = 0, relative = true, window = win }))
      hl.dispatch(hl.dsp.window.resize({ x = -1, y = 0, relative = true, window = win }))
      if at then hl.dispatch(hl.dsp.window.move({ x = at.x, y = at.y, window = win })) end
    end
    -- tap_fingers = 2: a two-finger tap, then the pinch -- the user's choice over the
    -- one-finger default, which they found unnatural (2026-10-08).
    Touch.gesture({ fingers = 2, kind = "tap_pinch", tap_fingers = 2, on = "pip",
      begin = function() z0 = tonumber(hl.get_config("decoration.keystone_pip_zoom")) or 3; last = z0 end,
      update = function(g)
        local z = math.max(1, math.min(8, z0 / math.max(g.scale, 0.05)))
        if last and math.abs(z - last) < last * 0.03 then return end -- ~3% steps: each one re-lays out the client
        last = z
        hl.config({ decoration = { keystone_pip_zoom = z } })
        if g.window then nudge(g.window.address) end
      end,
      finish = function()
        for _, w in ipairs(hl.get_windows()) do
          for _, t in ipairs(w.tags or {}) do
            if t == "pip" or t == "pip*" then nudge(w.address); break end
          end
        end
      end,
    })
  end
  -- Keystone (my.hyprland.keystone; the Hyprland fork's keystone-render commit): dock windows render as a
  -- perspective trapezoid. Only valid with the patch; stock Hyprland rejects these.
  -- Values from sihooleebd/nixos 0a7686c. rounding = corner radius (px) of the
  -- trapezoid plus edge anti-aliasing; the shadow is warped with the card.
  hl.config({ decoration = {
    keystone_inset = 0.07, keystone_shrink = 0.035, keystone_rounding = 24,
    keystone_shadow_range = 48, keystone_shadow_dx = 8, keystone_shadow_dy = 14,
    keystone_shadow_alpha = 0.5, keystone_parallax = 0,
    -- Card moves overshoot and settle, DAMPED along the pile: a card at depth d (front 0)
    -- overshoots by keystone_bounce * keystone_bounce_decay^d -- a continuous formula,
    -- evaluated per card by the patch (each card gets its own curve, since Hyprland reads
    -- a curve live and a shared one switched between cards bent those already moving).
    keystone_bounce = 0.2, keystone_bounce_decay = 0.5,
  } })
  -- A 3-finger swipe that starts on a pile card drives the pile live, in the panel's
  -- PHYSICAL frame (Hyprland fork, keystone dock-move-gestures):
  -- toward the dock edge the front card follows the fingers out and the one behind it
  -- comes up; away from it every card but the last follows, each deeper one lagging by
  -- dock_swipe_follow, and the last comes up. On release this settles it, or springs back.
  -- (gestures.dock_swipe_follow, default 0.75, tunes the lag.)
  hl.config({ gestures = { dock_swipe_exec = dock .. " gesture-move" } })
end
