--[[
  features/sidedock/dockswipe.lua -- the 5-finger touchscreen dock show/hide, LIVE: the
  pile follows the fingers, and letting go finishes the slide or springs it back.

  Until 2026-10-08 these were discrete swipes that ran `dock.sh show` / `hide` at the end.
  Now, required as feat.dockswipe by sidedock/hyprland.lua:

    begin   read the pile's layout from the cache dock.sh writes on every layout pass
            ($XDG_RUNTIME_DIR/sidedock.layout: each card's shown and parked position).
            A FILE read, not a dock.sh run: Hyprland's Lua runs on the compositor thread,
            and io.popen of a script making hyprctl calls would stall every frame.
            Showing opens the dock workspace (without the scratchpad's dim, as
            dockws_show does). Every card gets no_anim, so a move lands on the next
            tick instead of animating behind the fingers -- AnimationManager's
            handleUpdate warps any animated variable of a no_anim window.
    update  progress p = finger travel along the front card's parked->shown vector,
            0..1; each card is placed at the lerp between its two positions, deeper
            cards starting a little later (`lag` per depth) so the pile fans in.
    finish  commit past `commit` progress, or on a flick in the commit direction;
            otherwise revert. no_anim is unset FIRST, then `dock.sh settle show|hide`
            finishes from where the cards are, with the usual (bouncing) move curves.
    cancel  revert.

  Already in the target state (a "show" swipe with the dock up) the gesture does nothing.
  A missing or stale cache (wrong monitor transform, unknown windows) falls back to the
  discrete show/hide at the end, as before.
]]

local M = {}

M.defaults = {
  commit = 0.35,      -- progress past which letting go finishes the slide
  flick = 0.0025,     -- progress per ms: a faster release commits (or reverts) by direction
  lag = 0.08,         -- per depth: a deeper card starts this much later and catches up by p = 1
}

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end; return v end

local function readLayout(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local hdr = f:read("l")
  local t = hdr and tonumber(hdr:match("^v1 (%d+)"))
  if not t then f:close(); return nil end
  local cards = {}
  for line in f:lines() do
    local a, d, sx, sy, px, py = line:match("^(%S+) (%d+) (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)$")
    if a then
      cards[#cards + 1] = { a = a, d = tonumber(d), sx = tonumber(sx), sy = tonumber(sy), px = tonumber(px), py = tonumber(py) }
    end
  end
  f:close()
  if #cards == 0 then return nil end
  return { transform = t, cards = cards }
end

--[[
  M.new(o) -> controller with begin(mode, g) / update(g) / finish(g) / cancel(g).
  o.layout    path of the layout cache
  o.settle    fn(mode)   -- run `dock.sh settle <mode>`
  o.discrete  fn(mode)   -- the old discrete show/hide, for the fallback
  o.monitor   fn() -> { transform, special }  (special = the shown special workspace name)
  o.windows   fn() -> set of addresses that exist
  o.setNoAnim fn(addr, bool)
  o.move      fn(addr, x, y)
  o.openDock  fn()        -- open special:dock without the dim
  + any of M.defaults
]]
function M.new(o)
  local opt = setmetatable(o, { __index = M.defaults })
  local st = nil
  local C = {}

  local function place(p)
    st.p = p
    for _, c in ipairs(st.cards) do
      local lag = opt.lag * c.d
      local q = clamp((p - lag) / (1 - lag), 0, 1) -- a deeper card starts later, ends together
      local x, y
      if st.mode == "show" then
        x, y = c.px + (c.sx - c.px) * q, c.py + (c.sy - c.py) * q
      else
        x, y = c.sx + (c.px - c.sx) * q, c.sy + (c.py - c.sy) * q
      end
      opt.move(c.a, math.floor(x + 0.5), math.floor(y + 0.5))
    end
  end

  function C.begin(mode, g)
    st = { mode = mode, kind = "noop", p = 0, hist = {} }
    local m = opt.monitor() or {}
    local shown = m.special == "special:dock"
    if (mode == "show") == shown then return end -- already there
    local L = readLayout(opt.layout)
    local have = opt.windows()
    local ok = L and L.transform == (m.transform or 0) % 4
    if ok then for _, c in ipairs(L.cards) do if not have[c.a] then ok = false; break end end end
    if not ok then st.kind = "fallback"; return end
    local f = L.cards[1]
    st.kind = "live"; st.cards = L.cards
    st.vx, st.vy = f.sx - f.px, f.sy - f.py           -- parked -> shown
    if mode == "hide" then st.vx, st.vy = -st.vx, -st.vy end
    st.len2 = st.vx * st.vx + st.vy * st.vy
    if st.len2 < 1 then st.kind = "fallback"; return end
    if mode == "show" then opt.openDock() end
    for _, c in ipairs(st.cards) do opt.setNoAnim(c.a, true) end
    C.update(g)
  end

  function C.update(g)
    if not st or st.kind ~= "live" or not g or not g.delta then return end
    local p = clamp((g.delta.x * st.vx + g.delta.y * st.vy) / st.len2, 0, 1)
    local h = st.hist
    h[#h + 1] = { t = g.duration or 0, p = p }
    if #h > 6 then table.remove(h, 1) end
    place(p)
  end

  -- progress per ms over the last few updates
  local function velocity()
    local h = st.hist
    if #h < 2 then return 0 end
    local a, b = h[1], h[#h]
    if b.t <= a.t then return 0 end
    return (b.p - a.p) / (b.t - a.t)
  end

  local function done(commit)
    for _, c in ipairs(st.cards) do opt.setNoAnim(c.a, false) end
    local target = commit and st.mode or (st.mode == "show" and "hide" or "show")
    opt.settle(target)
  end

  function C.finish(g)
    if not st then return end
    local s = st
    if s.kind == "live" then
      if g then C.update(g) end
      local v = velocity()
      local commit
      if v > opt.flick then commit = s.p > 0.02
      elseif v < -opt.flick then commit = false
      else commit = s.p >= opt.commit end
      done(commit)
    elseif s.kind == "fallback" then
      opt.discrete(s.mode)
    end
    st = nil
    return s
  end

  function C.cancel()
    if not st then return end
    if st.kind == "live" then done(false) end
    st = nil
  end

  function C.state() return st end
  return C
end

M.readLayout = readLayout
return M
