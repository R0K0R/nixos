--[[
  Offline tests for features/hyprland/touch.lua: synthetic touch sequences through a mock
  `hl`, checking which gestures fire. Run from the repo root:

    nix shell nixpkgs#lua5_4 -c lua features/hyprland/tests/touch_test.lua

  The mock monitor is this laptop's panel: 2880x1800 at scale 1.5 = 1920x1200 logical.
]]

local log, timerObj = {}, nil
hl = {
  on = function() end,
  touch_swipe = function(phase, fingers, dx, dy) log[#log + 1] = ("swipe:%s:%s"):format(phase, fingers or "") end,
  touch_claim = function() log[#log + 1] = "claim"; return true end,
  get_config = function(k) if k == "gestures.touch_claim_fingers" then return 3 end end,
  get_monitor_at = function() return { x = 0, y = 0, width = 2880, height = 1800, scale = 1.5, transform = 0 } end,
  dispatch = function() end,
  dsp = { focus = function() return {} end },
  timer = function(fn, o)
    timerObj = { fn = fn, enabled = true, set_timeout = function(self) self.enabled = true end,
                 set_enabled = function(self, v) self.enabled = v end }
    return timerObj
  end,
}

local Touch = dofile("features/hyprland/touch.lua")

local function G(spec) return Touch.gesture(spec) end
local function act(name) return function(g) log[#log + 1] = name .. (g.shape and (":" .. g.shape) or "") end end
local function cont(name)
  return { begin = function() log[#log + 1] = name .. ":begin" end,
           update = function(g) log[#log + 1] = ("%s:update:%.2f"):format(name, g.scale or 1) end,
           finish = function() log[#log + 1] = name .. ":finish" end }
end
local function with(t, extra) for k, v in pairs(extra) do t[k] = v end; return t end

-- the default table, as the features define it
G({ fingers = 3, kind = "tap_drag", trackpad = 3 })
G({ fingers = 4, kind = "swipe", trackpad = 4 })
G({ fingers = 3, kind = "tap", taps = 2, action = act("pip-toggle") })
G({ fingers = 3, kind = "hold", action = act("float") })
G({ fingers = 4, kind = "tap", action = act("spotlight") })
G({ fingers = 4, kind = "hold", action = act("dock-toggle") })
G({ fingers = 5, kind = "tap", action = act("pip-showhide") })
G({ fingers = 5, kind = "swipe", direction = "down", action = act("close") })
G(with({ fingers = 2, kind = "tap_pinch", tap_fingers = 2, on = "pip" }, cont("pipzoom")))
-- extra kinds, exercised here only
G({ fingers = 1, kind = "draw", shape = "circle_cw", action = act("draw") })
G({ fingers = 1, kind = "draw", shape = "v", action = act("draw") })
G({ fingers = 2, kind = "edge_swipe", edge = "left", action = act("edge-left") })
G({ fingers = 2, kind = "shake", action = act("shake") })
G({ fingers = 1, kind = "chord", tap_fingers = 1, action = act("chord") })
G(with({ fingers = 2, kind = "rotate" }, cont("rotate")))
G({ fingers = 3, kind = "flick", direction = "up", action = act("flick-up"), priority = 1 })
G(with({ fingers = 1, kind = "edge_slide", edge = "right" }, cont("slide")))
G(with({ fingers = 6, kind = "pan" }, cont("pan")))
G(with({ fingers = 2, kind = "hold_drag", hold_ms = 500 }, cont("holddrag")))

local PIP = { address = "0xp", tags = { "dock", "pip" }, floating = true }
local WIN = { address = "0xw", tags = {}, floating = false }

local t = 1000
local function down(id, x, y, w) Touch._down({ id = id, x = x, y = y, time = t, window = w or WIN }) end
local function move(id, x, y) Touch._move({ id = id, x = x, y = y, time = t }) end
local function up(id) Touch._up({ id = id, time = t }) end
local function wait(ms) t = t + ms; Touch._tick(t) end
local function fingers(n, x, y, w) for i = 1, n do down(i, x + i * 40, y, w) end end
local function moveAll(n, x, y) for i = 1, n do move(i, x + i * 40, y) end end
local function lift(n) for i = 1, n do up(i) end end
local function tap(n, x, y, w) fingers(n, x, y, w); t = t + 80; lift(n) end

local fails = 0
local function check(name, want)
  local got = table.concat(log, " ")
  local ok = true
  for _, w in ipairs(want) do if not got:find(w, 1, true) then ok = false end end
  if want.absent then for _, w in ipairs(want.absent) do if got:find(w, 1, true) then ok = false end end end
  print((ok and "PASS " or "FAIL ") .. name .. (ok and "" or ("   got: " .. got)))
  if not ok then fails = fails + 1 end
  log = {}; Touch._reset(); t = t + 5000
end

tap(4, 600, 500)
check("4-finger tap -> spotlight at once (no double tap defined, nothing to wait for)", { "spotlight", absent = { "dock-toggle" } })

fingers(4, 600, 500); wait(600); lift(4)
check("4-finger hold -> dock toggle", { "dock-toggle", absent = { "spotlight" } })

tap(3, 600, 500); t = t + 150; fingers(3, 600, 500); for k = 1, 6 do t = t + 16; moveAll(3, 600 + k * 20, 500) end; lift(3)
check("3-finger tap, then drag -> live trackpad move", { "swipe:begin:3", "swipe:update", "swipe:end" })

fingers(4, 600, 400); for k = 1, 8 do t = t + 16; moveAll(4, 600, 400 - k * 25) end; lift(4)
check("4-finger swipe -> live trackpad swipe", { "swipe:begin:4", "swipe:update", "swipe:end" })

fingers(3, 600, 500); wait(600); lift(3)
check("3-finger hold -> float", { "float", absent = { "pip-toggle" } })

tap(3, 600, 500); t = t + 150; tap(3, 600, 500)
check("3-finger double tap -> PiP toggle (no wait: no longer chain defined)", { "pip-toggle" })

fingers(5, 400, 200); for k = 1, 10 do t = t + 20; moveAll(5, 400, 200 + k * 40) end; lift(5)
check("5-finger swipe down -> close", { "close", absent = { "pip-showhide" } })

tap(5, 400, 500)
check("5-finger tap -> pip show/hide", { "pip-showhide" })

tap(2, 1700, 1000, PIP); t = t + 150
down(1, 1700, 1000, PIP); down(2, 1760, 1000, PIP)
for k = 1, 6 do t = t + 16; move(1, 1700 - k * 15, 1000); move(2, 1760 + k * 15, 1000) end; up(1); up(2)
check("two-finger tap, then pinch on a PiP -> live PiP zoom, claimed", { "claim", "pipzoom:begin", "pipzoom:update", "pipzoom:finish" })

tap(1, 1700, 1000, PIP); t = t + 150
down(1, 1700, 1000, PIP); down(2, 1760, 1000, PIP)
for k = 1, 6 do t = t + 16; move(1, 1700 - k * 15, 1000); move(2, 1760 + k * 15, 1000) end; up(1); up(2)
check("one-finger tap, then pinch on a PiP -> not a zoom (needs two)", { absent = { "pipzoom" } })

down(1, 1700, 1000, WIN); down(2, 1760, 1000, WIN)
for k = 1, 6 do t = t + 16; move(1, 1700 - k * 15, 1000); move(2, 1760 + k * 15, 1000) end; up(1); up(2)
check("a pinch without the tap stays the app's", { absent = { "pipzoom" } })

down(1, 900, 400); for k = 1, 40 do local a = k / 40 * 2 * math.pi - math.pi / 2; t = t + 10; move(1, 900 + 150 * math.cos(a), 550 + 150 * math.sin(a)) end; up(1)
check("1-finger clockwise circle -> draw circle_cw", { "draw:circle_cw" })

down(1, 700, 300); for k = 1, 10 do t = t + 10; move(1, 700 + k * 10, 300 + k * 25) end; for k = 1, 10 do t = t + 10; move(1, 800 + k * 10, 550 - k * 25) end; up(1)
check("1-finger V -> draw v", { "draw:v" })

down(1, 10, 500); down(2, 12, 560); for k = 1, 8 do t = t + 15; move(1, 10 + k * 30, 500); move(2, 12 + k * 30, 560) end; up(1); up(2)
check("2 fingers from the left edge, inward -> edge_swipe", { "edge-left" })

down(1, 800, 500); down(2, 800, 560)
for k = 1, 8 do t = t + 40; local x = 800 + ((k % 2 == 0) and 60 or -60); move(1, x, 500); move(2, x, 560) end; up(1); up(2)
check("2-finger shake -> shake", { "shake" })

down(1, 500, 500); t = t + 400; down(2, 700, 500); t = t + 80; up(2); t = t + 200; up(1)
check("1 held + 1 tapping -> chord", { "chord" })

down(1, 800, 500); down(2, 900, 500)
for k = 1, 8 do t = t + 16; local a = k * 4 * math.pi / 180; move(1, 850 - 50 * math.cos(a), 500 - 50 * math.sin(a)); move(2, 850 + 50 * math.cos(a), 500 + 50 * math.sin(a)) end; up(1); up(2)
check("2-finger twist -> rotate", { "rotate:begin", "rotate:finish" })

fingers(3, 600, 800); for k = 1, 4 do t = t + 20; moveAll(3, 600, 800 - k * 60) end; lift(3)
check("3-finger fast flick up -> flick", { "flick-up" })

down(1, 1915, 300); for k = 1, 8 do t = t + 16; move(1, 1914, 300 + k * 30) end; up(1)
check("1 finger along the right edge -> edge_slide", { "slide:begin", "slide:finish" })

tap(3, 600, 500); wait(400)
check("3-finger single tap does nothing", { absent = { "pip-toggle", "float" } })

down(1, 800, 500); down(2, 900, 500); for k = 1, 8 do t = t + 16; move(1, 800 + k * 20, 500 + k * 10); move(2, 900 + k * 20, 500 + k * 10) end; up(1); up(2)
check("a 2-finger pan is not a rotation", { absent = { "rotate" } })

fingers(6, 300, 300); for k = 1, 5 do t = t + 16; moveAll(6, 300 + k * 20, 300) end; lift(6)
check("6-finger pan -> pan", { "pan:begin", "pan:update", "pan:finish" })

down(1, 800, 500, WIN); down(2, 900, 500, WIN); wait(550); for k = 1, 5 do t = t + 16; move(1, 800 + k * 20, 500); move(2, 900 + k * 20, 500) end; up(1); up(2)
check("2-finger hold, then drag -> hold_drag", { "holddrag:begin", "holddrag:finish" })

-- A first finger on a layer surface (the on-screen keyboard drawn over a PiP): the
-- sequence has no window, so `on =` gestures don't match, and g.layer names the surface.
local function downL(id, x, y, w, layer) Touch._down({ id = id, x = x, y = y, time = t, window = w, layer = layer }) end
downL(1, 1700, 1000, PIP, "wvkbd"); downL(2, 1760, 1000, PIP, "wvkbd"); t = t + 80; up(1); up(2); t = t + 150
downL(1, 1700, 1000, PIP, "wvkbd"); downL(2, 1760, 1000, PIP, "wvkbd")
for k = 1, 6 do t = t + 16; move(1, 1700 - k * 15, 1000); move(2, 1760 + k * 15, 1000) end; up(1); up(2)
check("two-finger tap, then pinch on the keyboard over a PiP -> not a PiP zoom", { absent = { "pipzoom", "claim" } })

G({ fingers = 7, kind = "tap", action = function(g) log[#log + 1] = "layer:" .. tostring(g.layer) .. ":" .. tostring(g.window) end })
for i = 1, 7 do downL(i, 200 + i * 40, 1100, WIN, "wvkbd") end; t = t + 80; lift(7); wait(400)
check("a tap on a layer surface reports g.layer and no window", { "layer:wvkbd:nil" })

-- ---------------------------------------------------------------- live 5-finger dock swipe
-- features/sidedock/dockswipe.lua driven through the recognizer, as sidedock/hyprland.lua
-- wires it, with the dock side mocked: a layout cache file, the shown special workspace,
-- the monitor transform. Moves, no_anim and settle calls are logged.
local DS = dofile("features/sidedock/dockswipe.lua")
local LAYOUT = os.tmpname()
local mon = { transform = 0, special = nil }
local function writeLayout(tr, cards)
  local f = io.open(LAYOUT, "w"); f:write(("v1 %d 0 0 1920 1200\n"):format(tr))
  for _, c in ipairs(cards) do f:write(table.concat(c, " ") .. "\n") end
  f:close()
end
-- landscape: the dock on the right, cards slide in along x (parked at 1920)
local LANDSCAPE = { { "0xa", 0, 1248, 84, 1920, 84 }, { "0xb", 1, 1227, 133, 1920, 84 } }
-- 90 deg: the dock along the bottom, cards slide up from y = 1920 (logical 1200x1920)
local PORTRAIT = { { "0xa", 0, 84, 1248, 84, 1920 }, { "0xb", 1, 133, 1227, 84, 1920 } }
local lastMove = {}
local Live = DS.new({
  layout = LAYOUT,
  settle = function(m) log[#log + 1] = "settle:" .. m end,
  discrete = function(m) log[#log + 1] = "discrete:" .. m end,
  monitor = function() return { transform = mon.transform, special = mon.special } end,
  windows = function() return { ["0xa"] = true, ["0xb"] = true } end,
  setNoAnim = function(a, on) log[#log + 1] = ("noanim:%s:%s"):format(a, on and "on" or "off") end,
  move = function(a, x, y) lastMove[a] = { x, y }; if a == "0xa" then log[#log + 1] = "move" end end,
  openDock = function() log[#log + 1] = "open" end,
})
local toward = function() return ({ [0] = "right", [1] = "down", [2] = "left", [3] = "up" })[mon.transform % 4] end
local opp = { right = "left", left = "right", up = "down", down = "up" }
for _, m in ipairs({ "show", "hide" }) do
  G({ fingers = 5, kind = "swipe", priority = 50,
      direction = function(d) if m == "show" then return d == opp[toward()] end; return d == toward() end,
      begin = function(g) Live.begin(m, g) end, update = function(g) Live.update(g) end,
      finish = function(g) Live.finish(g) end, cancel = function() Live.cancel() end })
end
-- n steps of (dx, dy) every ms milliseconds, five fingers
local function swipe5(x, y, dx, dy, n, ms)
  fingers(5, x, y); for k = 1, n do t = t + ms; moveAll(5, x + k * dx, y + k * dy) end; lift(5)
end

writeLayout(0, LANDSCAPE); mon.transform = 0; mon.special = nil
swipe5(1000, 600, -40, 0, 10, 30)  -- 400 px left over 300 ms: p ~ 0.6
check("dock hidden, 5-finger swipe away from the edge -> live show, commits", { "open", "noanim:0xa:on", "move", "noanim:0xa:off", "settle:show", absent = { "settle:hide", "close" } })
local mid = lastMove["0xa"] and lastMove["0xa"][1]
print(((mid and mid < 1920 and mid > 1248) and "PASS " or "FAIL ") .. "front card tracked the fingers (x " .. tostring(mid) .. ")")
if not (mid and mid < 1920 and mid > 1248) then fails = fails + 1 end

swipe5(1000, 600, -10, 0, 15, 40)  -- 150 px slowly: p ~ 0.22, no flick
check("short slow show swipe -> springs back", { "settle:hide", absent = { "settle:show" } })

swipe5(1000, 600, -50, 0, 3, 16)   -- 150 px in 48 ms: a flick
check("short fast show flick -> commits", { "settle:show" })

mon.special = "special:dock"
swipe5(1000, 600, -40, 0, 10, 30)
check("dock already shown: a show swipe does nothing", { absent = { "move", "settle", "open", "discrete" } })

swipe5(1000, 600, 40, 0, 10, 30)   -- toward the edge
check("dock shown, swipe toward the edge -> live hide, commits", { "noanim:0xa:on", "move", "settle:hide", absent = { "open", "settle:show" } })

writeLayout(1, PORTRAIT); mon.transform = 1; mon.special = nil
swipe5(600, 1000, 0, -40, 10, 30)  -- 90 deg: away from the bottom edge = up
check("rotated 90: swipe up (away from the physical edge) -> live show", { "open", "move", "settle:show", absent = { "close" } })
mon.special = "special:dock"
swipe5(600, 600, 0, 40, 10, 30)    -- rotated, toward the dock = down: beats the 5-finger close
check("rotated 90: swipe down -> live hide, not close", { "settle:hide", absent = { "close" } })

writeLayout(0, LANDSCAPE); mon.transform = 1; mon.special = nil  -- cache from before a rotation
swipe5(600, 1000, 0, -40, 10, 30)
check("stale cache (other transform) -> discrete show at the end", { "discrete:show", absent = { "move", "settle" } })
os.remove(LAYOUT)

print(fails == 0 and "all passed" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
