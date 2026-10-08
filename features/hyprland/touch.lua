--[[
  features/hyprland/touch.lua -- touchscreen gestures, recognized in Lua.

  The compositor (patches/keystone/11-touchscreen-swipes) recognizes nothing itself:
  it streams every touch here as input.touch.down / move / up / cancel and offers two
  primitives -- hl.touch_claim() (take the sequence from its client) and
  hl.touch_swipe(phase, fingers, dx, dy) (drive the TRACKPAD gesture machinery, so a
  touch gesture can run any hl.gesture entry live: the workspace swipe, scroll_move,
  move and the side-dock card swipe). Gestures are therefore pure config: edit, reload,
  done -- no rebuild. Until 2026-10-08 the 3-finger tap-drag and the 4-finger swipe were
  hardcoded in Touch.cpp, and every new gesture meant a Hyprland build.

  Usage, from any feature's hyprland.lua:

    local Touch = require("feat.touch")
    Touch.gesture{ fingers = 4, kind = "tap", action = function(g) ... end }

  A spec:
    fingers    how many fingers the gesture is made with (default 1)
    kind       see KINDS below
    on         window filter, tested on the window under the first finger: "pip",
               "dock" (a pile card), "float", "tiled", a class name, or a
               function(window) -> bool. nil = any (also no window at all).
    action     fn(g) -- discrete kinds call it once; continuous kinds call it at the end
    begin / update / finish / cancel
               fn(g) for continuous kinds (finish also gets action if no finish)
    trackpad   N -- continuous kinds: feed the motion to hl.touch_swipe as an N-finger
               trackpad swipe, i.e. whatever hl.gesture{fingers = N} does, live
    focus      false: don't focus the window under the fingers before a trackpad swipe
    claim      true: take the touches from the client as soon as the gesture starts
               (automatic at >= gestures:touch_claim_fingers fingers anyway)
    priority   number added to the specificity score (see CONFLICTS)
    + any default below, overridden for this gesture only (e.g. hold_ms = 900)

  KINDS (discrete = fires once at the end; continuous = begin/update/finish while moving):
    tap          discrete. taps = 1, 2, 3 ... (a tap chain: each within double_tap_gap
                 of the last, near it). No movement past tap_slop, down <= tap_ms.
    hold         discrete. still for hold_ms. Fires at once -- unless a hold_drag with
                 the same fingers exists, then on release without moving.
    hold_drag    continuous. hold (hold_ms), then move.
    tap_drag     continuous. a tap (tap_fingers, default = fingers) then, within
                 tap_gesture_gap, fingers down again and moving. The "move" gesture.
    tap_pinch    continuous. a tap (tap_fingers, default 1) then a 2+-finger pinch.
    tap_rotate   continuous. a tap (tap_fingers, default 1) then a 2+-finger twist.
    swipe        discrete, or continuous if it has trackpad/begin/update. direction
                 ("left" "right" "up" "down" "up_left" "up_right" "down_left"
                 "down_right" "horizontal" "vertical" "diagonal", nil = any, or a
                 function(direction) -> bool decided at match time),
                 min (px), distance ("short" "medium" "long": at least that share of
                 the screen along the swipe), edge / corner (where the centroid
                 started: "left" "right" "top" "bottom" / "top_left" ...).
    flick        discrete. a swipe faster than flick_velocity (px/ms) within flick_ms.
    edge_swipe   discrete. a swipe that STARTS within edge_px of an edge (edge = ...)
                 or corner (corner = ...), moving inward.
    edge_slide   continuous. one finger starting at an edge, moving ALONG it -- g.delta
                 along the edge, e.g. brightness on the left edge, volume on the right.
    pinch        continuous; direction "in" / "out" makes action conditional on the
                 final scale. g.scale = finger spread / spread at start.
    rotate       continuous; direction "cw" / "ccw" likewise. g.rotation in degrees.
    pan          continuous. multi-finger translation, g.delta.
    chord        discrete (alias hold_tap). `fingers` held still while tap_fingers
                 (default 1) other fingers tap.
    draw         discrete. a one-finger stroke matched against shape = "circle_cw"
                 "circle_ccw" "v" "caret" "l" "z" "check" "s" "zigzag" "line_up" ...
                 ("line_" + any direction). g.shape, g.score (0 best).
    shake        discrete (alias scrub). rapid back-and-forth: shake_reversals turns of
                 at least shake_amplitude px within shake_ms.

  g, given to every callback: fingers, window, centroid {x,y}, start {x,y}, delta {x,y}
  (since the gesture started), scale, rotation, velocity (px/ms), direction, edge,
  corner, distance, taps, duration (ms), shape, score.

  CONFLICTS: of the gestures that match, the most specific wins -- more fingers, then
  more taps, then a window filter, then `priority`. A tap whose chain could still grow
  (a double tap or a tap_* with the same fingers is defined) waits double_tap_gap for
  the next one, so a single tap then fires that much later.

  Lifting a finger of a running continuous gesture finishes it; another finger landing
  cancels it. A finger that started a border resize (resizing = true) is ignored.
]]

local Touch = {}

Touch.defaults = {
  tap_ms = 250,          -- a tap's fingers all lift within this
  tap_slop = 20,         -- px a tap finger may wander
  move_slop = 15,        -- px of centroid travel before a continuous gesture starts
  double_tap_gap = 300,  -- ms between the taps of a chain
  tap_gesture_gap = 400, -- ms from a tap to the fingers of a tap_drag / tap_pinch / tap_rotate
  tap_near = 120,        -- px: the next tap of a chain lands this close to the last
  hold_ms = 550,
  swipe_min = 80,        -- px for a discrete swipe
  flick_velocity = 1.2,  -- px/ms
  flick_ms = 350,
  edge_px = 32,          -- how close to an edge "from the edge" starts
  pinch_threshold = 0.12,  -- |scale - 1|
  rotate_threshold = 15,   -- degrees
  draw_min = 120,        -- px of stroke length before shapes are considered
  draw_score = 0.32,     -- max mean distance (unit box) for a shape match
  shake_reversals = 3,
  shake_amplitude = 30,
  shake_ms = 1200,
}

local D = Touch.defaults
local function opt(spec, k) local v = spec[k]; if v == nil then return D[k] end; return v end

local CONTINUOUS = { hold_drag = true, tap_drag = true, tap_pinch = true, tap_rotate = true,
                     edge_slide = true, pinch = true, rotate = true, pan = true }
local KINDS = { tap = true, hold = true, swipe = true, flick = true, edge_swipe = true,
                chord = true, draw = true, shake = true }
for k in pairs(CONTINUOUS) do KINDS[k] = true end
local ALIAS = { hold_tap = "chord", scrub = "shake" }

local gestures = {}

function Touch.gesture(spec)
  spec.kind = ALIAS[spec.kind] or spec.kind
  if not KINDS[spec.kind] then error("Touch.gesture: unknown kind " .. tostring(spec.kind)) end
  spec.fingers = spec.fingers or 1
  if spec.kind == "tap" then spec.taps = spec.taps or 1 end
  if spec.kind == "tap_drag" then spec.tap_fingers = spec.tap_fingers or spec.fingers end
  if spec.kind == "tap_pinch" or spec.kind == "tap_rotate" then
    spec.fingers = math.max(spec.fingers, 2); spec.tap_fingers = spec.tap_fingers or 1
  end
  if spec.kind == "pinch" or spec.kind == "rotate" then spec.fingers = math.max(spec.fingers, 2) end
  if spec.kind == "chord" then spec.tap_fingers = spec.tap_fingers or 1 end
  gestures[#gestures + 1] = spec
  return spec
end

function Touch.set(overrides) for k, v in pairs(overrides) do D[k] = v end end
function Touch.clear() gestures = {} end

-- ---------------------------------------------------------------- helpers

local function hasTag(w, name)
  local hit = false
  pcall(function()
    for _, t in ipairs(w.tags) do if t == name or t == name .. "*" then hit = true; break end end
  end)
  return hit
end

local function matchOn(spec, w)
  local on = spec.on
  if on == nil then return true end
  if not w then return false end
  if type(on) == "function" then local ok, r = pcall(on, w); return ok and r end
  if on == "pip" then return hasTag(w, "pip") end
  if on == "dock" then return hasTag(w, "dock") and not hasTag(w, "pip") end
  if on == "float" then return w.floating == true end
  if on == "tiled" then return w.floating == false end
  return w.class == on
end

local function specificity(spec)
  return (spec.fingers or 1) * 1000 + (spec.taps or 0) * 100 + (spec.on and 10 or 0) + (spec.priority or 0)
end

-- gestures of the given kinds for n fingers whose filter accepts w, most specific first
local function candidates(kinds, n, w, pred)
  local out = {}
  for _, s in ipairs(gestures) do
    if kinds[s.kind] and s.fingers == n and matchOn(s, w) and (not pred or pred(s)) then out[#out + 1] = s end
  end
  table.sort(out, function(a, b) return specificity(a) > specificity(b) end)
  return out
end

local function set(...) local t = {}; for _, k in ipairs({ ... }) do t[k] = true end; return t end

local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

local DIRS = { "right", "down_right", "down", "down_left", "left", "up_left", "up", "up_right" }
local function direction8(dx, dy)
  local a = math.atan(dy, dx) -- screen: y grows downward
  local i = math.floor((a / (math.pi / 4)) + 0.5) % 8
  return DIRS[i + 1]
end
local function dirMatches(want, got)
  if want == nil or want == "any" then return true end
  -- a function decides at match time: e.g. a direction in the panel's PHYSICAL frame,
  -- which moves with the monitor transform (features/sidedock's dock swipes)
  if type(want) == "function" then return want(got) == true end
  if want == "horizontal" then return got == "left" or got == "right" end
  if want == "vertical" then return got == "up" or got == "down" end
  if want == "diagonal" then return got:find("_") ~= nil end
  return want == got
end

-- the logical rectangle of the monitor at (x, y)
local function monitorAt(x, y)
  local ok, m = pcall(hl.get_monitor_at, { x = x, y = y })
  if not ok or not m then return nil end
  local s = (m.scale and m.scale > 0) and m.scale or 1
  local w, h = m.width / s, m.height / s
  if (m.transform or 0) % 2 == 1 then w, h = h, w end -- width/height are the mode's, unrotated
  return { x = m.x, y = m.y, w = w, h = h }
end

local function edgeOf(x, y, px)
  local m = monitorAt(x, y)
  if not m then return nil, nil, nil end
  local l, r = x - m.x <= px, m.x + m.w - x <= px
  local t, b = y - m.y <= px, m.y + m.h - y <= px
  local h = l and "left" or (r and "right" or nil)
  local v = t and "top" or (b and "bottom" or nil)
  local corner = (h and v) and (v .. "_" .. h) or nil
  return h or v, corner, m
end

-- ---------------------------------------------------------------- shapes ($1-style)

local SHAPES = {}
local function line(dx, dy) return { { 0, 0 }, { dx, dy } } end
for _, d in ipairs(DIRS) do
  local a = (({ right = 0, down_right = 1, down = 2, down_left = 3, left = 4, up_left = 5, up = 6, up_right = 7 })[d]) * math.pi / 4
  SHAPES["line_" .. d] = line(math.cos(a), math.sin(a))
end
local function circle(cw)
  local pts = {}
  for i = 0, 32 do
    local a = (cw and 1 or -1) * i / 32 * 2 * math.pi - math.pi / 2
    pts[#pts + 1] = { math.cos(a), math.sin(a) }
  end
  return pts
end
SHAPES.circle_cw, SHAPES.circle_ccw = circle(true), circle(false)
SHAPES.v = { { 0, 0 }, { 0.5, 1 }, { 1, 0 } }
SHAPES.caret = { { 0, 1 }, { 0.5, 0 }, { 1, 1 } }
SHAPES.l = { { 0, 0 }, { 0, 1 }, { 0.6, 1 } }
SHAPES.z = { { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 1 } }
SHAPES.check = { { 0, 0.6 }, { 0.35, 1 }, { 1, 0 } }
SHAPES.s = { { 1, 0 }, { 0, 0.1 }, { 0, 0.45 }, { 1, 0.55 }, { 1, 0.9 }, { 0, 1 } }
SHAPES.zigzag = { { 0, 0 }, { 0.25, 1 }, { 0.5, 0 }, { 0.75, 1 }, { 1, 0 } }

local N = 32
local function pathLen(p) local L = 0; for i = 2, #p do L = L + dist(p[i - 1][1], p[i - 1][2], p[i][1], p[i][2]) end; return L end
local function resample(p)
  local I, Dacc, out = pathLen(p) / (N - 1), 0, { { p[1][1], p[1][2] } }
  local pts = {}; for i, q in ipairs(p) do pts[i] = { q[1], q[2] } end
  local i = 2
  while i <= #pts do
    local d = dist(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2])
    if I > 0 and Dacc + d >= I then
      local t = (I - Dacc) / d
      local q = { pts[i - 1][1] + t * (pts[i][1] - pts[i - 1][1]), pts[i - 1][2] + t * (pts[i][2] - pts[i - 1][2]) }
      out[#out + 1] = q; table.insert(pts, i, q); Dacc = 0
    else Dacc = Dacc + d end
    i = i + 1
  end
  while #out < N do out[#out + 1] = { pts[#pts][1], pts[#pts][2] } end
  return out
end
-- scale to the unit box keeping the aspect (a vertical line stays a line), centre on 0
local function normalize(p)
  local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
  for _, q in ipairs(p) do minx = math.min(minx, q[1]); maxx = math.max(maxx, q[1]); miny = math.min(miny, q[2]); maxy = math.max(maxy, q[2]) end
  local s = math.max(maxx - minx, maxy - miny); if s == 0 then s = 1 end
  local cx, cy = 0, 0
  local out = {}
  for i, q in ipairs(p) do out[i] = { (q[1] - minx) / s, (q[2] - miny) / s }; cx = cx + out[i][1]; cy = cy + out[i][2] end
  cx, cy = cx / #out, cy / #out
  for _, q in ipairs(out) do q[1] = q[1] - cx; q[2] = q[2] - cy end
  return out
end
local TEMPL = {}
for name, pts in pairs(SHAPES) do TEMPL[name] = normalize(resample(pts)) end
local function matchShape(path)
  local p = normalize(resample(path))
  local best, bestScore = nil, math.huge
  for name, t in pairs(TEMPL) do
    local s = 0
    for i = 1, N do s = s + dist(p[i][1], p[i][2], t[i][1], t[i][2]) end
    s = s / N
    if s < bestScore then best, bestScore = name, s end
  end
  return best, bestScore
end
Touch.matchShape = matchShape -- exposed for tests / tuning

-- ---------------------------------------------------------------- state

local touches = {}  -- id -> {x, y, x0, y0, t0, t, win, path, resizing}
local seq = nil     -- the current sequence (first finger down .. last finger up)
local lastTap = nil -- {fingers, count, tEnd, x, y, win}
local pendingTap = nil -- a tap chain waiting to see if it grows: {deadline, fire = fn}
local active = nil  -- a running continuous gesture
local lastTime = 0
local timer = nil

local function down() local ids = {}; for id, t in pairs(touches) do if not t.resizing then ids[#ids + 1] = id end end; table.sort(ids); return ids end
local function centroid(ids) local x, y = 0, 0; for _, id in ipairs(ids) do x = x + touches[id].x; y = y + touches[id].y end; return x / #ids, y / #ids end
local function spread(ids, cx, cy) local s = 0; for _, id in ipairs(ids) do s = s + dist(touches[id].x, touches[id].y, cx, cy) end; return s / #ids end
local function angles(ids, cx, cy) local a = {}; for _, id in ipairs(ids) do a[id] = math.atan(touches[id].y - cy, touches[id].x - cx) end; return a end
local function key(ids) return table.concat(ids, ",") end

local function call(fn, g) if fn then local ok, err = pcall(fn, g); if not ok then print("touch.lua: " .. tostring(err)) end end end

-- ---------------------------------------------------------------- timer

local deadlines = {} -- name -> {at, fn}

local function arm()
  local soonest = nil
  for _, d in pairs(deadlines) do if not soonest or d.at < soonest then soonest = d.at end end
  if not timer then
    if not soonest then return end
    local ok, t = pcall(hl.timer, function() Touch._tick() end, { timeout = 1000, type = "repeat" })
    if not ok then return end
    timer = t
  end
  if soonest then timer:set_timeout(math.max(1, math.floor(soonest - lastTime))) else timer:set_enabled(false) end
end

local function at(name, when, fn) deadlines[name] = { at = when, fn = fn }; arm() end
local function clearAt(name) deadlines[name] = nil; arm() end

-- the timer fired: run every deadline that is due, the clock taken as the soonest one
function Touch._tick(now)
  if not now then
    now = math.huge
    for _, d in pairs(deadlines) do if d.at < now then now = d.at end end
    if now == math.huge then if timer then timer:set_enabled(false) end; return end
  end
  lastTime = math.max(lastTime, now)
  for name, d in pairs(deadlines) do
    if d.at <= now then deadlines[name] = nil; local ok, err = pcall(d.fn, now); if not ok then print("touch.lua: " .. tostring(err)) end end
  end
  arm()
end

-- ---------------------------------------------------------------- g

local function makeG(spec, extra)
  local ids = down()
  local g = { fingers = spec and spec.fingers or #ids, window = seq and seq.win, taps = 0, scale = 1, rotation = 0, velocity = 0 }
  if #ids > 0 then local cx, cy = centroid(ids); g.centroid = { x = cx, y = cy } end
  for k, v in pairs(extra or {}) do g[k] = v end
  return g
end

-- ---------------------------------------------------------------- continuous gestures

local function finishActive(how) -- how: "finish" | "cancel"
  local a = active
  if not a then return end
  active = nil
  if a.spec.trackpad then hl.touch_swipe(how == "cancel" and "cancel" or "end") end
  if how == "cancel" then call(a.spec.cancel, a.g)
  else
    local ok = true
    if a.spec.kind == "pinch" or a.spec.kind == "tap_pinch" then
      if a.spec.direction == "in" then ok = a.g.scale < 1 elseif a.spec.direction == "out" then ok = a.g.scale > 1 end
    elseif a.spec.kind == "rotate" or a.spec.kind == "tap_rotate" then
      if a.spec.direction == "cw" then ok = a.g.rotation > 0 elseif a.spec.direction == "ccw" then ok = a.g.rotation < 0 end
    end
    if ok then call(a.spec.finish or a.spec.action, a.g) end
  end
  if seq then seq.consumed = true end
end

local function measure(a, now)
  local ids = {}
  for _, id in ipairs(a.ids) do if touches[id] then ids[#ids + 1] = id end end
  if #ids == 0 then return end
  local cx, cy = centroid(ids)
  local g = a.g
  g.centroid = { x = cx, y = cy }
  g.delta = { x = cx - a.c0x, y = cy - a.c0y }
  g.duration = now - a.t0
  if g.duration > 0 then g.velocity = dist(cx, cy, a.c0x, a.c0y) / g.duration end
  g.direction = direction8(g.delta.x, g.delta.y)
  if #ids >= 2 and a.s0 and a.s0 > 1 then
    g.scale = spread(ids, cx, cy) / a.s0
    local ang, sum, n = angles(ids, cx, cy), 0, 0
    for id, v in pairs(ang) do
      if a.a0[id] then
        local d = v - a.a0[id]
        while d > math.pi do d = d - 2 * math.pi end
        while d < -math.pi do d = d + 2 * math.pi end
        sum = sum + d; n = n + 1
      end
    end
    if n > 0 then g.rotation = math.deg(sum / n) end -- positive = clockwise on screen
  end
  return cx, cy
end

local function startActive(spec, now, base)
  local ids = down()
  local a = { spec = spec, ids = ids, t0 = now, c0x = base.cx, c0y = base.cy, s0 = base.s, a0 = base.a,
              lastx = base.cx, lasty = base.cy }
  a.g = makeG(spec, { start = { x = base.cx, y = base.cy }, taps = seq.armed and seq.armed.count or 0, edge = base.edge, corner = base.corner })
  active = a
  clearAt("hold")
  -- below the compositor's claim threshold the client still has these touches: take
  -- them when the gesture asks to, or when it is aimed at a window (`on`) or drives a
  -- trackpad gesture -- either way the client should not act on them too
  local okc, cf = pcall(hl.get_config, "gestures.touch_claim_fingers")
  local claimN = (okc and tonumber(cf)) or 3
  if spec.claim == true or (spec.claim ~= false and #ids < claimN and (spec.on ~= nil or spec.trackpad)) then
    pcall(hl.touch_claim)
  end
  if spec.kind == "tap_drag" or spec.kind == "tap_pinch" or spec.kind == "tap_rotate" then lastTap = nil end
  if spec.trackpad then
    if spec.focus ~= false and seq.win and seq.win.address then
      pcall(hl.dispatch, hl.dsp.focus({ window = "address:" .. seq.win.address }))
    end
    hl.touch_swipe("begin", spec.trackpad)
  end
  local cx, cy = measure(a, now)
  call(spec.begin, a.g)
  if spec.trackpad and cx then
    hl.touch_swipe("update", spec.trackpad, cx - a.c0x, cy - a.c0y) -- the travel so far, so the dispatcher sees the direction
    a.lastx, a.lasty = cx, cy
  end
  call(spec.update, a.g)
end

-- a baseline for the fingers down now: continuous thresholds are measured from it
local function baseline(now)
  local ids = down()
  if #ids == 0 then return nil end
  local k = key(ids)
  if seq.base and seq.base.key == k then return seq.base end
  local cx, cy = centroid(ids)
  local edge, corner = edgeOf(cx, cy, D.edge_px)
  seq.base = { key = k, n = #ids, cx = cx, cy = cy, s = spread(ids, cx, cy), a = angles(ids, cx, cy), t = now, edge = edge, corner = corner }
  return seq.base
end

-- try to start a continuous gesture with the fingers down now
local function tryContinuous(now)
  if active then return end
  local base = baseline(now)
  if not base then return end
  local ids = down()
  local n = #ids
  local cx, cy = centroid(ids)
  local travel = dist(cx, cy, base.cx, base.cy)
  local scale = (n >= 2 and base.s > 1) and spread(ids, cx, cy) / base.s or 1
  local rot = 0
  if n >= 2 then
    local ang, sum, k = angles(ids, cx, cy), 0, 0
    for id, v in pairs(ang) do if base.a[id] then local d = v - base.a[id]; while d > math.pi do d = d - 2 * math.pi end; while d < -math.pi do d = d + 2 * math.pi end; sum = sum + d; k = k + 1 end end
    if k > 0 then rot = math.deg(sum / k) end
  end
  local armed = seq.armed -- set at the sequence's first finger if a tap ended within tap_gesture_gap

  local kinds = set("hold_drag", "tap_drag", "tap_pinch", "tap_rotate", "edge_slide", "pinch", "rotate", "pan", "swipe")
  for _, s in ipairs(candidates(kinds, n, seq.win)) do
    local k = s.kind
    local slop = opt(s, "move_slop")
    local ok = false
    if k == "tap_drag" then ok = armed and armed.fingers == s.tap_fingers and travel >= slop
    elseif k == "tap_pinch" then ok = armed and armed.fingers == s.tap_fingers and math.abs(scale - 1) >= opt(s, "pinch_threshold")
    elseif k == "tap_rotate" then ok = armed and armed.fingers == s.tap_fingers and math.abs(rot) >= opt(s, "rotate_threshold")
    elseif k == "hold_drag" then ok = seq.held == n and travel >= slop
    elseif k == "pinch" then ok = math.abs(scale - 1) >= opt(s, "pinch_threshold")
    elseif k == "rotate" then ok = math.abs(rot) >= opt(s, "rotate_threshold")
    elseif k == "edge_slide" then
      if n == 1 and base.edge and (s.edge == nil or s.edge == base.edge) and travel >= slop then
        local along = (base.edge == "left" or base.edge == "right") and math.abs(cy - base.cy) or math.abs(cx - base.cx)
        ok = along >= travel * 0.7
      end
    elseif k == "pan" then ok = travel >= slop
    elseif k == "swipe" and (s.trackpad or s.begin or s.update) then
      ok = travel >= slop and dirMatches(s.direction, direction8(cx - base.cx, cy - base.cy))
           and (s.edge == nil or s.edge == base.edge) and (s.corner == nil or s.corner == base.corner)
    end
    if ok then startActive(s, now, base); return end
  end
end

-- ---------------------------------------------------------------- discrete gestures

local function maxTapsFor(n, w)
  -- only a longer TAP chain is worth waiting for. A tap_* prefix is not: the tap fires
  -- at once, and if the fingers come back and drag within tap_gesture_gap the tap_*
  -- gesture runs too -- far cheaper than delaying every tap by double_tap_gap.
  local m = 0
  for _, s in ipairs(gestures) do
    if s.kind == "tap" and s.fingers == n and matchOn(s, w) then m = math.max(m, s.taps) end
  end
  return m
end

local function fireTap(n, count, w, x, y)
  local c = candidates(set("tap"), n, w, function(s) return s.taps == count end)
  if c[1] then call(c[1].action, { fingers = n, taps = count, window = w, centroid = { x = x, y = y }, start = { x = x, y = y }, delta = { x = 0, y = 0 }, scale = 1, rotation = 0, velocity = 0 }) end
end

local function countReversals(path, horizontal, amp)
  local rev, dirn, anchor = 0, 0, nil
  for _, p in ipairs(path) do
    local v = horizontal and p[1] or p[2]
    if not anchor then anchor = v
    else
      local d = v - anchor
      if dirn >= 0 and d <= -amp then rev = rev + (dirn > 0 and 1 or 0); dirn = -1; anchor = v
      elseif dirn <= 0 and d >= amp then rev = rev + (dirn < 0 and 1 or 0); dirn = 1; anchor = v
      elseif (dirn > 0 and v > anchor) or (dirn < 0 and v < anchor) then anchor = v end
    end
  end
  return rev
end

local function endSequence(now)
  local s = seq
  seq = nil
  clearAt("hold")
  if s.consumed then return end
  local n = s.maxFingers
  local dur = now - s.t0
  -- the motion of the whole sequence: the mean of every finger's start and end
  local sx, sy, ex, ey, k = 0, 0, 0, 0, 0
  for _, f in pairs(s.finished) do sx = sx + f.x0; sy = sy + f.y0; ex = ex + f.x; ey = ey + f.y; k = k + 1 end
  if k == 0 then return end
  sx, sy, ex, ey = sx / k, sy / k, ex / k, ey / k
  local dx, dy = ex - sx, ey - sy
  local d = dist(sx, sy, ex, ey)
  local w = s.win

  if not s.moved and dur <= D.tap_ms and not s.held then
    -- a tap: extend the chain if it continues the last one
    local count = 1
    if lastTap and lastTap.fingers == n and s.t0 - lastTap.tEnd <= D.double_tap_gap and dist(sx, sy, lastTap.x, lastTap.y) <= D.tap_near then
      count = lastTap.count + 1
    end
    lastTap = { fingers = n, count = count, tEnd = now, x = sx, y = sy, win = w }
    if count < maxTapsFor(n, w) then
      pendingTap = true
      at("tap", now + D.double_tap_gap, function() pendingTap = nil; fireTap(n, count, w, sx, sy) end)
    else
      fireTap(n, count, w, sx, sy)
    end
    return
  end

  if s.heldFire then -- a hold whose hold_drag never moved fires on release
    call(s.heldFire.action, makeG(s.heldFire, { window = w, duration = dur }))
    return
  end
  if not s.moved then return end

  local edge, corner, m = edgeOf(sx, sy, D.edge_px)
  local dirn = direction8(dx, dy)
  local vel = dur > 0 and d / dur or 0
  local extent = m and ((dirn == "left" or dirn == "right") and m.w or ((dirn == "up" or dirn == "down") and m.h or math.sqrt(m.w ^ 2 + m.h ^ 2))) or 1000
  local share = d / extent
  local distance = share >= 0.66 and "long" or (share >= 0.33 and "medium" or "short")
  local CLASS = { short = 1, medium = 2, long = 3 }
  local g = { fingers = n, window = w, start = { x = sx, y = sy }, centroid = { x = ex, y = ey }, delta = { x = dx, y = dy },
              velocity = vel, direction = dirn, edge = edge, corner = corner, distance = distance, duration = dur,
              taps = 0, scale = 1, rotation = 0 }

  local first = s.finished[s.firstId]
  local kinds = set("shake", "draw", "flick", "edge_swipe", "swipe")
  for _, c in ipairs(candidates(kinds, n, w)) do
    local ok = false
    local kd = c.kind
    if kd == "shake" and first and dur <= opt(c, "shake_ms") then
      local rh = countReversals(first.path, true, opt(c, "shake_amplitude"))
      local rv = countReversals(first.path, false, opt(c, "shake_amplitude"))
      ok = math.max(rh, rv) >= opt(c, "shake_reversals")
    elseif kd == "draw" and n == 1 and first and pathLen(first.path) >= opt(c, "draw_min") then
      local name, score = matchShape(first.path)
      if name == c.shape and score <= opt(c, "draw_score") then ok = true; g.shape = name; g.score = score end
    elseif kd == "flick" then
      ok = vel >= opt(c, "flick_velocity") and dur <= opt(c, "flick_ms") and dirMatches(c.direction, dirn)
    elseif kd == "edge_swipe" then
      ok = d >= opt(c, "swipe_min") and edge ~= nil and dirMatches(c.direction, dirn)
           and (c.edge == nil or c.edge == edge) and (c.corner == nil or c.corner == corner)
    elseif kd == "swipe" and not (c.trackpad or c.begin or c.update) then
      ok = d >= (c.min or opt(c, "swipe_min")) and dirMatches(c.direction, dirn)
           and (c.distance == nil or CLASS[distance] >= CLASS[c.distance])
           and (c.edge == nil or c.edge == edge) and (c.corner == nil or c.corner == corner)
    end
    if ok then call(c.action, g); return end
  end
end

-- ---------------------------------------------------------------- events

local flushFrame -- defined with Touch._move below; down/lift flush the pending frame too

local function scheduleHold(now)
  local ids = down()
  local n = #ids
  if n == 0 or active then clearAt("hold"); return end
  local holdMs = nil
  for _, s in ipairs(gestures) do
    if (s.kind == "hold" or s.kind == "hold_drag") and s.fingers == n and matchOn(s, seq.win) then
      local h = opt(s, "hold_ms"); holdMs = holdMs and math.min(holdMs, h) or h
    end
  end
  if not holdMs then clearAt("hold"); return end
  local since = seq.stillSince or now
  at("hold", since + holdMs, function(t)
    if not seq or active or #down() ~= n or seq.movedSinceStill then return end
    local drag = candidates(set("hold_drag"), n, seq.win)
    local hold = candidates(set("hold"), n, seq.win)
    seq.held = n
    if drag[1] then
      seq.heldFire = hold[1] -- fires on release if the drag never starts
    elseif hold[1] then
      seq.consumed = true
      call(hold[1].action, makeG(hold[1], { duration = t - seq.t0 }))
    end
  end)
end

function Touch._down(e)
  local now = e.time or lastTime
  lastTime = math.max(lastTime, now)
  flushFrame()
  if not seq then
    seq = { t0 = now, maxFingers = 0, finished = {}, win = e.window, firstId = e.id, moved = false }
    -- a tap just before arms the tap_* kinds
    if lastTap and now - lastTap.tEnd <= D.tap_gesture_gap then seq.armed = lastTap end
    -- a pending tap chain is superseded by this new sequence (it may extend it)
    if pendingTap then clearAt("tap"); pendingTap = nil end
  end
  touches[e.id] = { x = e.x, y = e.y, x0 = e.x, y0 = e.y, t0 = now, t = now, win = e.window, path = { { e.x, e.y } } }
  if active then finishActive("cancel") end
  local n = #down()
  if n > seq.maxFingers then seq.maxFingers = n end
  seq.base = nil
  seq.stillSince, seq.movedSinceStill = now, false
  -- tap_pinch / tap_rotate on a filtered window take the touches as soon as their fingers land
  if seq.armed then
    for _, s in ipairs(candidates(set("tap_pinch", "tap_rotate"), n, seq.win)) do
      if s.tap_fingers == seq.armed.fingers and s.on ~= nil then pcall(hl.touch_claim); break end
    end
  end
  -- chord: a finger landing while the others have been HELD (down >= tap_ms). Without
  -- the wait, the fingers of an ordinary multi-finger tap -- which never land quite
  -- together -- read as a chord.
  if n >= 2 and not seq.chordBase and now - seq.t0 >= D.tap_ms then seq.chordBase = n - 1 end
  scheduleHold(now)
end

--[[
  Motion is evaluated once per FRAME, not per event. Each finger's motion arrives as its
  own event, and one frame's events share a timestamp; evaluated per event, a two-finger
  translation looked like a twist halfway through every frame (one finger moved, the
  other not yet) -- rotate fired on a plain pan, and live scale updates jittered 0.91 /
  1.00 within a frame. So a frame is evaluated when the next one starts (an event with a
  newer time) or a finger lands or lifts.
]]
flushFrame = function()
  if not seq or not seq.dirty then return end
  seq.dirty = false
  local now = seq.frameT
  if active then
    local a = active
    local cx, cy = measure(a, now)
    if a.spec.trackpad and cx then
      hl.touch_swipe("update", a.spec.trackpad, cx - a.lastx, cy - a.lasty)
      a.lastx, a.lasty = cx, cy
    end
    call(a.spec.update, a.g)
    return
  end
  tryContinuous(now)
end
Touch._flush = flushFrame

function Touch._move(e)
  local t = touches[e.id]
  if not t then return end
  local now = e.time or lastTime
  lastTime = math.max(lastTime, now)
  if e.resizing then t.resizing = true; return end
  if seq.frameT ~= now then flushFrame(); seq.frameT = now end
  t.x, t.y, t.t = e.x, e.y, now
  local p = t.path
  if #p < 512 then p[#p + 1] = { e.x, e.y } end
  if dist(t.x, t.y, t.x0, t.y0) > D.tap_slop then
    seq.moved = true
    if not seq.movedSinceStill then seq.movedSinceStill = true; clearAt("hold") end
  end
  seq.dirty = true
end

local function lift(e, cancelled)
  local t = touches[e.id]
  if not t then return end
  flushFrame()
  local now = e.time or lastTime
  lastTime = math.max(lastTime, now)
  touches[e.id] = nil
  if not seq then return end
  if not t.resizing then
    seq.finished[e.id] = { x0 = t.x0, y0 = t.y0, x = t.x, y = t.y, t0 = t.t0, path = t.path }
  end
  if cancelled then
    if active then finishActive("cancel") end
    seq.consumed = true
  elseif active then
    for _, id in ipairs(active.ids) do if id == e.id then finishActive("finish"); break end end
  else
    -- chord: a quick, still finger lifted while earlier fingers stay down
    local quick = (now - t.t0) <= D.tap_ms and dist(t.x, t.y, t.x0, t.y0) <= D.tap_slop
    local remaining = #down()
    if quick and seq.chordBase and remaining >= seq.chordBase and t.t0 > seq.t0 then
      seq.chordTaps = (seq.chordTaps or 0) + 1
      if remaining == (seq.chordBase or remaining) then
        local c = candidates(set("chord"), remaining, seq.win, function(s) return s.tap_fingers == seq.chordTaps end)
        if c[1] then seq.consumed = true; call(c[1].action, makeG(c[1], { taps = seq.chordTaps })) end
        seq.chordTaps = 0
      end
    end
  end
  if next(touches) == nil then endSequence(now)
  else
    seq.base = nil
    seq.stillSince, seq.movedSinceStill = now, false
    scheduleHold(now)
  end
end

function Touch._up(e) lift(e, false) end
function Touch._cancel(e) lift(e, true) end

-- for tests: forget everything
function Touch._reset() touches, seq, lastTap, pendingTap, active, deadlines = {}, nil, nil, nil, nil, {} end

if hl and hl.on then
  pcall(hl.on, "input.touch.down", function(e) Touch._down(e) end)
  pcall(hl.on, "input.touch.move", function(e) Touch._move(e) end)
  pcall(hl.on, "input.touch.up", function(e) Touch._up(e) end)
  pcall(hl.on, "input.touch.cancel", function(e) Touch._cancel(e) end)
end

return Touch
