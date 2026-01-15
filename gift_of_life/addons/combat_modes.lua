-- addons/combat_modes.lua
-- "Combat Modes" addon for Gift of Life.
-- Auto-switches fight/chase modes based on HP and panic pause.

local A = {}
local _evt = nil
local _loadToken = 0
local _lastSet = 0

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
    tickMs = 350,
    safeHpPct = 60,
    fightModeHigh = 2,
    fightModeLow = 1,
    chaseOn = 1,
    chaseOff = 0,
    rateLimitMs = 600,
  }
  if type(centralCfg) == "table" and type(centralCfg.addons) == "table" and type(centralCfg.addons.combat_modes) == "table" then
    cfg = deepMerge(cfg, centralCfg.addons.combat_modes.cfg or {})
  end
  return cfg
end

local function applyModes(cfg, isSafe, forceStop)
  if not g_game then return end
  local t = nowMs()
  if (t - _lastSet) < (tonumber(cfg.rateLimitMs) or 600) then return end
  _lastSet = t

  if forceStop then
    if type(g_game.setChaseMode) == "function" then pcall(g_game.setChaseMode, tonumber(cfg.chaseOff) or 0) end
    return
  end

  local fight = isSafe and cfg.fightModeHigh or cfg.fightModeLow
  local chase = isSafe and cfg.chaseOn or cfg.chaseOn

  if type(g_game.setFightMode) == "function" and fight ~= nil then pcall(g_game.setFightMode, tonumber(fight) or 2) end
  if type(g_game.setChaseMode) == "function" and chase ~= nil then pcall(g_game.setChaseMode, tonumber(chase) or 1) end
end

function A.init(entry, centralCfg)
  _loadToken = _loadToken + 1
  local token = _loadToken

  local cfg = resolveCfg(centralCfg)
  if entry and type(entry) == "table" then
    cfg = deepMerge(cfg, entry.cfg or {})
  end

  stopEvent()
  local tickMs = math.max(120, math.min(1200, tonumber(cfg.tickMs) or 350))
  _evt = scheduleTick(function()
    if token ~= _loadToken then return end
    if not cfg.enabled then return end
    if not isOnline() then return end

    local p = getPlayer()
    if not p then return end

    if paused() then
      applyModes(cfg, false, true)
      return
    end

    local hp = hpPct(p)
    local safe = hp >= (tonumber(cfg.safeHpPct) or 60)
    applyModes(cfg, safe, false)
  end, tickMs)

  safePrint("[GoL][CombatModes] init")
end

function A.shutdown()
  stopEvent()
  _loadToken = _loadToken + 1
  safePrint("[GoL][CombatModes] shutdown")
end

return A
