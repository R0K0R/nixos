-- features/waydroid: Super+Q on the Waydroid window puts it away instead of
-- closing it -- hidden on the `waydroid` special workspace, Android's display
-- off. Closing the window crashes Android's hwcomposer (see home.nix); every
-- other window still closes as usual. Loaded after features/hyprland's file, whose
-- HyprCloseWindow this wraps.

local nix = require("nix.waydroid")

-- Wraps features/hyprland's HyprCloseWindow, which Super+Q and the 5-finger touch close
-- both go through.
local closeWindow = HyprCloseWindow
function HyprCloseWindow(w)
  if w and w.class == "Waydroid" then
    -- a side-dock card leaves the pile first, or the next dock show brings it back
    -- with its display off: a black card (features/sidedock, when present)
    if SideDockRelease then SideDockRelease(w) end
    hl.dispatch(hl.dsp.exec_cmd(nix.hide .. " " .. w.address))
  else
    closeWindow(w)
  end
end

-- Android never learns that a window is hidden: Hyprland marks it suspended and
-- stops its frame callbacks, but Waydroid's hwcomposer runs its own vsync and
-- ignores both, so a hidden app kept animating (Melon: its UI and render
-- threads ~720 wakeups/s, surfaceflinger ~1700/s, on the hidden side dock).
-- Sleeping the display would close every app window, so instead Android's
-- animations stop while no Waydroid window is on screen (scale 0 makes an
-- animator jump to its end; playback is untouched): UI+render ~100/s,
-- surfaceflinger ~350/s.
local animOn = nil

local function waydroidShown()
  for _, w in ipairs(hl.get_windows()) do
    local c = w.class or ""
    if (c == "Waydroid" or c:sub(1, 9) == "waydroid.") and w.mapped and not w.hidden
        and w.workspace and w.workspace.active then
      return true
    end
  end
  return false
end

local function syncAnim()
  local shown = waydroidShown()
  if shown == animOn then return end
  animOn = shown
  hl.dispatch(hl.dsp.exec_cmd(nix.anim .. (shown and " on" or " off")))
end

-- Deferred: some events fire before the workspace or window state they report
-- is applied (see dim_special in features/hyprland).
for _, e in ipairs({ "window.open", "window.close", "window.destroy", "window.move_to_workspace",
                     "workspace.active", "workspace.special_active", "monitor.removed" }) do
  hl.on(e, function() hl.timer(syncAnim, { timeout = 100, type = "oneshot" }) end)
end
