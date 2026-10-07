-- features/waydroid: Super+Q on the Waydroid window puts it away instead of
-- closing it -- hidden on the `waydroid` special workspace, Android's display
-- off. Closing the window crashes Android's hwcomposer (see home.nix); every
-- other window still closes as usual. Loaded after features/hyprland's file,
-- whose Super+Q this replaces (Hyprland appends duplicate binds: unbind first).

local nix = require("nix.waydroid")
local mod = nix.mod

hl.unbind(mod .. " + Q")
hl.bind(mod .. " + Q", function()
  local w = hl.get_active_window()
  if w and w.class == "Waydroid" then
    hl.dispatch(hl.dsp.exec_cmd(nix.hide .. " " .. w.address))
  else
    hl.dispatch(hl.dsp.window.close())
  end
end)
