-- addons/smart_kite.lua
-- "Smart Kite" addon for Gift of Life.
-- When HP is low, attempts to step away from adjacent monsters (simple kiting).

local A = {}
local _evt = nil
local _loadToken = 0
local _lastStep = 0

local function nowMs()
  if g_clock and type(g_clock.millis) == "function" then
    local ok, v = pcall(g_clock.millis)
    if ok then return v end
  end
  return os.time() * 1000
end

local function isOnline()
  return g_game and type(g_game.isOnline) == "function" and g_game.isOnline()
end

local function getPlayer()
  return g_game and type(g_game.getLocalPlayer) == "function" and g_game.getLocalPlayer() or nil
end

local function getPos(p)
  if not p then return nil end
  if type(p.getPosition) == "function" then
    local ok, pos = pcall(p.getPosition, p)
    if ok then return pos end
  end
  return nil
end

local function hpPct(p)
  if not p then return 100 end
  if type(p.getHealthPercent) == "function" then
    local ok, v = pcall(p.getHealthPercent, p)
    if ok and type(v) == "number" then return v end
  end
  return 100
end

local function paused()
  local G = _G.GiftOfLife
  if not G then return false end
  local u = tonumber(G._panicPauseUntil) or 0
  return nowMs() < u
end

local function scheduleTick(fn, ms)
  if type(cycleEvent) == "function" then return cycleEvent(fn, ms) end
  if type(scheduleEvent) == "function" then
    local function loop()
      fn()
      _evt = scheduleEvent(loop, ms)
    end
    _evt = scheduleEvent(loop, ms)
    return _evt
  end
  return nil
end

local function stopEvent()
  if _evt and type(removeEvent) == "function" then pcall(removeEvent, _evt) end
  _evt = nil
end

local function safePrint(msg)
  if print then pcall(print, msg) end
end

local function deepMerge(dst, src)
  if type(src) ~= "table" then return dst end
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      deepMerge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function resolveCfg(centralCfg)
  local cfg = {
    enabled = true,
    tickMs = 120,
    hpBelow = 45,
    stepCooldownMs = 350,
    scanRange = 2,
  }
  if type(centralCfg) == "table" and type(centralCfg.addons) == "table" and type(centralCfg.addons.smart_kite) == "table" then
    cfg = deepMerge(cfg, centralCfg.addons.smart_kite.cfg or {})
  end
  return cfg
end

local function getSpectatorsAround(pos, range)
  if not (g_map and type(g_map.getSpectators) == "function") then return {} end
  local ok, list = pcall(g_map.getSpectators, pos, false, range, range)
  if ok and type(list) == "table" then return list end
  ok, list = pcall(g_map.getSpectators, pos, false)
  if ok and type(list) == "table" then return list end
  return {}
end

local function isMonster(c)
  if not c then return false end
  if type(c.isMonster) == "function" then
    local ok, v = pcall(c.isMonster, c)
    if ok then return v == true end
  end
  return false
end

local function getCreaturePos(c)
  if c and type(c.getPosition) == "function" then
    local ok, pos = pcall(c.getPosition, c)
    if ok then return pos end
  end
  return nil
end

local function distCheb(a, b)
  local ax, ay = a.x or 0, a.y or 0
  local bx, by = b.x or 0, b.y or 0
  local dx = ax - bx; if dx < 0 then dx = -dx end
  local dy = ay - by; if dy < 0 then dy = -dy end
  return dx > dy and dx or dy
end

local DIR = {
  N = 0, E = 1, S = 2, W = 3,
  NE = 4, SE = 5, SW = 6, NW = 7,
}

local function tryWalk(dir)
  if g_game and type(g_game.walk) == "function" then
    pcall(g_game.walk, dir)
  elseif g_game and type(g_game.forceWalk) == "function" then
    pcall(g_game.forceWalk, dir)
  end
end

local function stepAway(ppos, mpos)
  local dx = (ppos.x or 0) - (mpos.x or 0)
  local dy = (ppos.y or 0) - (mpos.y or 0)

  -- Choose the axis that increases distance most.
  if math.abs(dx) >= math.abs(dy) then
    if dx >= 0 then tryWalk(DIR.E) else tryWalk(DIR.W) end
  else
    if dy >= 0 then tryWalk(DIR.S) else tryWalk(DIR.N) end
  end
end

function A.init(entry, centralCfg)
  _loadToken = _loadToken + 1
  local token = _loadToken

  local cfg = resolveCfg(centralCfg)
  if entry and type(entry) == "table" then
    cfg = deepMerge(cfg, entry.cfg or {})
  end

  stopEvent()
  local tickMs = math.max(60, math.min(500, tonumber(cfg.tickMs) or 120))
  _evt = scheduleTick(function()
    if token ~= _loadToken then return end
    if not cfg.enabled then return end
    if paused() then return end
    if not isOnline() then return end

    local p = getPlayer()
    local ppos = getPos(p)
    if not ppos then return end

    if hpPct(p) > (tonumber(cfg.hpBelow) or 45) then return end

    local t = nowMs()
    if (t - _lastStep) < (tonumber(cfg.stepCooldownMs) or 350) then return end

    -- Find adjacent monster
    local best = nil
    local bestD = 999
    local specs = getSpectatorsAround(ppos, tonumber(cfg.scanRange) or 2)
    for _, c in ipairs(specs) do
      if isMonster(c) then
        local cpos = getCreaturePos(c)
        if cpos and cpos.z == ppos.z then
          local d = distCheb(ppos, cpos)
          if d < bestD then
            bestD = d
            best = cpos
          end
        end
      end
    end

    if best and bestD <= 1 then
      _lastStep = t
      stepAway(ppos, best)
    end
  end, tickMs)

  safePrint("[GoL][SmartKite] init")
end

function A.shutdown()
  stopEvent()
  _loadToken = _loadToken + 1
  safePrint("[GoL][SmartKite] shutdown")
end

return A
