-- features/dms: DMS's half of the Hyprland config (shell binds, layer rules,
-- live colours). Loaded after features/hyprland's file; see compositor.nix for
-- why it lives in the shell's feature rather than the compositor's.

local nix = require("nix.dms")
local mod = nix.mod

-- DMS's own live colors. Its Hyprland theming writes colors.lua
-- (general.col.*, group.col.*) as a single hl.config call, which
-- features/hyprland deliberately leaves unset so there is nothing to
-- race. layout.lua is NOT required, and must not be: it sets
-- border_size = 2, and the compositor keeps border_size = 0 because the
-- touchscreen workspace-swipe activation strip is
-- (gaps_out + border_size) / screen_height -- see the note beside those
-- values in features/hyprland/home.nix.
-- ~/.config/hypr is already on package.path: Hyprland puts its config dir
-- there itself.
require("dms.colors")

-- Glassmorphism for DMS layer surfaces. The compositor enables blur;
-- a layer surface has to opt in, which is what these do. ignore_alpha
-- skips near-fully-transparent pixels (the empty regions of the bar
-- surface) so they don't render as a hazy smear.
hl.layer_rule({ match = { namespace = "^(dms.*)$" }, no_anim = true, blur = true, ignore_alpha = 0.05 })
-- The on-screen keyboard (plugins/osk-keyboard, namespace dms-osk) above every other
-- Overlay surface. Spotlight is on Overlay too here (modalDarkenBackground puts DMS
-- modals there), and within a layer the last-mapped surface is on top: opened while
-- the keyboard was up, spotlight's full-screen click-catcher covered it, and the first
-- key tapped closed spotlight instead of typing. `order` sorts a layer descending
-- (Renderer.cpp arrangeLayersForMonitor), first drawn = bottom, and hit tests walk it
-- from the top -- so a NEGATIVE order is above the default 0, for drawing and input.
hl.layer_rule({ match = { namespace = "^(dms-osk)$" }, order = -100 })
-- The on-screen keyboard (./plugins/osk-keyboard) is the "dms-osk" layer, so the
-- rule above frosts it too.

-- Shell surfaces.
hl.bind(mod .. " + space", hl.dsp.exec_cmd("dms ipc call spotlight toggle"))
-- ... and a four-finger tap on the touchscreen (features/hyprland/touch.lua)
pcall(function()
  require("feat.touch").gesture({ fingers = 4, kind = "tap", action = function()
    hl.dispatch(hl.dsp.exec_cmd("dms ipc call spotlight toggle"))
  end })
end)
-- Alt+Tab = Spotlight pre-filled with the altTab plugin's trigger
-- (plugins.nix, ./plugins/alt-tab): windows in MRU order, live
-- previews. openQuery rather than toggleQuery so a second Alt+Tab
-- while it is up re-asserts instead of closing. Arrows/Enter inside.
hl.bind("ALT + Tab", hl.dsp.exec_cmd("dms ipc call spotlight openQuery !"))
hl.bind(mod .. " + I", hl.dsp.exec_cmd("dms ipc call settings toggle"))
hl.bind(mod .. " + A", hl.dsp.exec_cmd("dms ipc call plugins toggle aiAssistant"))
hl.bind(mod .. " + N", hl.dsp.exec_cmd("dms ipc call notifications toggle"))
hl.bind(mod .. " + V", hl.dsp.exec_cmd("dms ipc call clipboard toggle"))
hl.bind(mod .. " + X", hl.dsp.exec_cmd("dms ipc call powermenu toggle"))
hl.bind(mod .. " + M", hl.dsp.exec_cmd("dms ipc call processlist toggle"))
hl.bind(mod .. " + ALT + N", hl.dsp.exec_cmd("dms ipc call night toggle"))
hl.bind(mod .. " + ALT + L", hl.dsp.exec_cmd("dms ipc call lock lock"))

-- Hold Super to reveal the workspace numbers. hl.dsp.global routes to
-- Hyprland's global-shortcuts protocol, which delivers press AND
-- release -- ./plugins/workspaces' GlobalShortcut turns those straight
-- into its `peeking` flag. A plain bind fires once and would need a
-- second release bind plus shared state to reconstruct a hold.
--
-- BARE KEY, ignore_mods, transparent -- the shape end-4/dots-hyprland
-- uses for exactly this gesture, arrived at after the obvious spellings
-- failed here.
--
-- Not "SUPER + Super_L": binding a modifier under its own modmask
-- cannot match on press, per KeybindManager.cpp
--
--   652:  if (... (modmask != k->modmask && !k->ignoreMods) ...) continue;
--   744:  // key.modmaskAtPressTime is set from currently pressed keys as
--         // programs see them, but it doesn't yet include the currently
--         // pressed mod key
--
-- When Super_L goes down Hyprland's modmask is still 0 while the bind
-- demands SUPER (64). ignore_mods alone got press working, but release
-- was still dropped whenever the hold had been USED for a combo
-- (Super+1, Super+W), which latched the peek on.
--
-- transparent is the missing half: KeybindManager.cpp:867 exempts it
-- from shadowing alongside `global`, and it stops the bind interfering
-- with every other Super combo -- so Super keeps working as a modifier
-- AND both edges get delivered.
--
-- Both physical Super keys, since either can start the hold.
--
-- The seam-drag plugin takes the same hold, for the opposite reason:
-- Super+drag moves a window, but its handles sit on the window edges
-- and would eat the drag, so they unmap while Super is down. Same
-- ignore_mods/transparent/release shape, and transparent means several
-- globals can share one key without shadowing each other.
for _, k in ipairs({ "SUPER_L", "SUPER_R" }) do
  hl.bind(k, hl.dsp.global("dms-workspaces:peek"),
          { ignore_mods = true, transparent = true })
  hl.bind(k, hl.dsp.global("dms-workspaces:peek"),
          { ignore_mods = true, transparent = true, release = true })
  hl.bind(k, hl.dsp.global("dms-seamdrag:suppress"),
          { ignore_mods = true, transparent = true })
  hl.bind(k, hl.dsp.global("dms-seamdrag:suppress"),
          { ignore_mods = true, transparent = true, release = true })
end

-- Media/brightness keys: repeating + fires even while locked.
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("dms ipc call audio increment 3"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("dms ipc call audio decrement 3"), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd('dms ipc call brightness increment 5 ""'), { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd('dms ipc call brightness decrement 5 ""'), { locked = true, repeating = true })

-- Mute: locked (fires once already locked) but not repeating.
hl.bind("XF86AudioMute", hl.dsp.exec_cmd("dms ipc call audio mute"), { locked = true })
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("dms ipc call audio micmute"), { locked = true })

-- Transport keys. Volume and mute were bound; play/next/prev never
-- were, so anything sending them did nothing at all -- including Galaxy
-- Buds taps, which arrive over Bluetooth AVRCP as ordinary XF86Audio*
-- key events, not as some separate headset channel.
--
-- locked = true matters more here than for volume: controlling playback
-- from the buds with the laptop closed is the whole point.
--
-- The target need not be a local player. DMS drives whatever MPRIS
-- players exist, and KDE Connect publishes the phone's and Waydroid's
-- as org.mpris.MediaPlayer2.kdeconnect.mpris_* on this session bus, so
-- these keys reach a Waydroid app the same way they reach mpv.
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("dms ipc call mpris playPause"), { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("dms ipc call mpris pause"), { locked = true })
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("dms ipc call mpris stop"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("dms ipc call mpris next"), { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("dms ipc call mpris previous"), { locked = true })

hl.bind("switch:on:Lid Switch", hl.dsp.exec_cmd(nix.lidClose), { locked = true })
hl.bind("switch:off:Lid Switch", hl.dsp.exec_cmd(nix.lidOpen), { locked = true })
