-- features/hakuspace: Haku Space's shell binds and layer rules for Hyprland.
-- Loaded after features/hyprland's file; see compositor.nix.

local nix = require("nix.hakuspace")
local mod = nix.mod
local function bin(name) return nix.binDir .. "/" .. name end

-- Launcher, menus and the notification centre.
hl.bind(mod .. " + R", hl.dsp.exec_cmd("rofi -show drun"))
hl.bind(mod .. " + SLASH", hl.dsp.exec_cmd("rofi -modi emoji -show emoji"))
hl.bind(mod .. " + TAB", hl.dsp.exec_cmd(bin("hakumenu.sh")))
hl.bind(mod .. " + N", hl.dsp.exec_cmd("swaync-client -t -sw"))
hl.bind(mod .. " + V", hl.dsp.exec_cmd(bin("clipboard_menu.sh")))
hl.bind(mod .. " + SHIFT + V", hl.dsp.exec_cmd(bin("clipboard_menu.sh") .. " --wipe"))

-- Session.
hl.bind(mod .. " + K", hl.dsp.exec_cmd(bin("lock.sh")), { locked = true })
hl.bind(mod .. " + L", hl.dsp.exec_cmd(bin("nightlight_toggle.sh")))

-- Appearance: wallpaper, the cava underbar, and the bar layout cycle.
hl.bind(mod .. " + Y", hl.dsp.exec_cmd(bin("wallpaper_select.sh")))
hl.bind(mod .. " + SHIFT + Y", hl.dsp.exec_cmd(bin("wallpaper_video_select.sh")))
hl.bind(mod .. " + T", hl.dsp.exec_cmd(bin("cava_manager.sh")))
hl.bind(mod .. " + SHIFT + W", hl.dsp.exec_cmd(bin("waybar_manager.sh") .. " --cycle"))

-- Capture.
hl.bind(mod .. " + F11", hl.dsp.exec_cmd(bin("record.sh")))

-- TWO BINDS MOVED OFF UPSTREAM'S DEFAULTS, because features/hyprland
-- already owns those keys and a duplicate bind in Hyprland is decided by
-- registration order rather than reported:
--
--   SUPER + W          upstream: dockbar toggle
--                      here:     firefox (features/hyprland app spawns)
--                      moved to: SUPER + SHIFT + B
--
--   SUPER + SHIFT + P  upstream: fullscreen screenshot
--                      here:     dpms off (features/hyprland)
--                      moved to: SUPER + CTRL + P
--
-- SUPER + P keeps its upstream key, the plain screenshot. features/sidedock
-- also wants it (PiP show/hide), and SUPER + CTRL + P (PiP toggle); the two
-- are not meant to be enabled together, and if they are, Hyprland decides by
-- registration order.
hl.bind(mod .. " + P", hl.dsp.exec_cmd(bin("screenshot.sh")))
hl.bind(mod .. " + CTRL + P", hl.dsp.exec_cmd(bin("screenshot.sh") .. " --fullscreen"))
hl.bind(mod .. " + SHIFT + B", hl.dsp.exec_cmd(bin("dockbar_manager.sh") .. " --toggle"))

-- Glassmorphism for the bar and the launcher, matching what
-- features/hyprland enables compositor-side. A layer surface has to opt
-- into blur; only windows get it automatically.
hl.layer_rule({ match = { namespace = "^(waybar)$" }, blur = true, ignore_alpha = 0.05 })
hl.layer_rule({ match = { namespace = "^(rofi)$" }, blur = true, ignore_alpha = 0.05 })
hl.layer_rule({ match = { namespace = "^(swaync.*)$" }, blur = true, ignore_alpha = 0.05 })
