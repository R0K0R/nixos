-- features/foldpen: keys for the phone stylus (the phone itself uses 3-finger
-- gestures: tap = mirror, hold = edit rectangle, swipe sideways = finger mode).
--
-- Device binding is NOT here: the daemon binds foldpen-stylus / foldpen-touch
-- to whichever monitor the input rectangle is on, at runtime (hl.device via
-- hyprctl eval), and overrides the rotation transform the panel's tablet and
-- touch get in features/hyprland.

local nix = require("nix.foldpen")
local fp = nix.foldpen

-- edit the input rectangle: drag it, wheel to resize, Esc / right click done
hl.bind(nix.mod .. " + ALT + R", hl.dsp.exec_cmd(fp .. " toggle edit"))
-- mirror the rectangle to the phone
hl.bind(nix.mod .. " + ALT + M", hl.dsp.exec_cmd(fp .. " toggle display"))
-- fingers on the phone: pen <-> touchscreen
hl.bind(nix.mod .. " + ALT + F", hl.dsp.exec_cmd(fp .. " toggle finger"))
