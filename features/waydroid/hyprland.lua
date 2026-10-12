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
