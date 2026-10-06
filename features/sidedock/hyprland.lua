-- features/sidedock: Hyprland half of the side dock (from sihooleebd/nixos 0a7686c).
--
-- Light apps live on a right-edge panel as a CASCADE STACK, on the `scratch` special
-- workspace (the scratchpad), so DMS's workspace strip never lists them. Every placement in
-- dock.sh is by window address, never by focusing, so main-area windows are
-- left alone. Upstream's wallpaper repaint and opendisplay hooks are left out;
-- the dock is driven by the keys below and the 3-finger swipe (the patched
-- move gesture, configured at the bottom).

local nix = require("nix.sidedock")
local mod = nix.mod
local dock = nix.dock

-- One auto-route rule per docked app: FLOATING, PINNED (follows the live workspace),
-- no initial focus, at a monitor-RELATIVE first frame (percentages of the logical
-- monitor). dock.sh is the authority on geometry: `adopt` (fired on window.open below)
-- re-sizes, size-locks and places the card from the live, logical geometry.
--
-- The rule does NOT tag the window 'dock': a rule tag reads as "dock*" and cannot be
-- removed by the tag dispatcher, so an auto-routed window could never be undocked.
-- The window.open handler recognises it by CLASS and dock.sh applies a dynamic tag.
-- Border off (drawn at the flat box, not warped); blur and shadow stay on, since the
-- keystone patch warps both to the trapezoid.
local dockClasses = {}
for _, c in ipairs(nix.classes) do
  dockClasses[c] = true
  hl.window_rule({ match = { class = "^(" .. c .. ")$" }, float = true, size = "33% 88%", move = "66% 8%",
    opacity = "1.0 1.0", pin = true, border_size = 0, rounding = 0, no_initial_focus = true })
end

hl.bind(mod .. " + " .. nix.keys.toggle, hl.dsp.exec_cmd(dock .. " toggle"))
-- The dock as a workspace: send the focused window there, or back out.
hl.bind(mod .. " + " .. nix.keys.dockToggle, hl.dsp.exec_cmd(dock .. " dock-toggle"))
hl.bind(mod .. " + " .. nix.keys.terminal, hl.dsp.exec_cmd("kitty --class " .. nix.termClass))
hl.bind(mod .. " + " .. nix.keys.prev, hl.dsp.exec_cmd(dock .. " prev"))
hl.bind(mod .. " + " .. nix.keys.next, hl.dsp.exec_cmd(dock .. " next"))
-- Picture-in-picture: the focused window becomes a pinned, keystoned mini-card
-- bottom-right (a `pip` tag keeps it out of the pile); again to put it back.
hl.bind(mod .. " + " .. nix.keys.pip, hl.dsp.exec_cmd(dock .. " pip-toggle"))

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
  hl.on("window.active", function(w)
    local addr = w and w.address or nil
    if addr == focusAddr then return end
    prevFocusDock = focusDock
    focusDock = w ~= nil and isDockWin(w) and not isPip(w)
    focusAddr = addr
  end)

  hl.on("window.open", function(w)
    if not w then return end
    if w.class and dockClasses[w.class] then
      hl.dispatch(hl.dsp.exec_cmd(dock .. " adopt " .. w.address))
      return
    end
    local dockHadFocus = focusDock
    if focusAddr == w.address then dockHadFocus = prevFocusDock end
    if dockHadFocus and not w.floating then
      hl.dispatch(hl.dsp.exec_cmd(dock .. " send " .. w.address))
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

  -- Mod+Ctrl+C on a pile card: the card already lives on the scratchpad, and moving it
  -- off by hand would strand it still tagged as a card. Undock it properly instead.
  hl.unbind(mod .. " + CTRL + C")
  hl.bind(mod .. " + CTRL + C", function()
    if onPileCard() then hl.dispatch(hl.dsp.exec_cmd(dock .. " dock-toggle")) else HyprScratchToggle() end
  end)

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

  local startDrag = hl.dsp.window.drag()
  hl.unbind(mod .. " + mouse:272")
  hl.bind(mod .. " + mouse:272", function()
    local overDock = false
    pcall(function()
      local c = hl.get_cursor_pos()
      for _, w in ipairs(hl.get_windows()) do
        if isDockWin(w) and not w.hidden
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
hl.animation({ leaf = "windowsMove", enabled = true, speed = 5, bezier = "dockslide" })

if nix.keystone then
  -- Keystone (my.hyprland.keystone, trapezoid.patch): dock windows render as a
  -- perspective trapezoid. Only valid with the patch; stock Hyprland rejects these.
  -- Values from sihooleebd/nixos 0a7686c. rounding = corner radius (px) of the
  -- trapezoid plus edge anti-aliasing; the shadow is warped with the card.
  hl.config({ decoration = {
    keystone_inset = 0.07, keystone_shrink = 0.035, keystone_rounding = 24,
    keystone_shadow_range = 48, keystone_shadow_dx = 8, keystone_shadow_dy = 14,
    keystone_shadow_alpha = 0.5, keystone_parallax = 0,
  } })
  -- A 3-finger swipe that starts on a pile card moves that card under the finger
  -- (trapezoid.patch's move gesture); on release this settles it: cycle or spring back.
  hl.config({ gestures = { dock_swipe_exec = dock .. " gesture-move" } })
end
