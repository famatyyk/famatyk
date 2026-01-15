-- addons/panic_guard.lua
-- "Panic Guard" addon for Gift of Life.
-- Pauses other automation when players appear on screen or HP drops too low.
-- Reload-safe: provide shutdown().

local A = {}
local _evt = nil
local _loadToken = 0

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

local function scheduleTick(fn, ms)
  if type(cycleEvent) == "function" then
    return cycleEvent(fn, ms)
  end
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

local function pushUi(msg)
  local G = _G.GiftOfLife
  if G and type(G.pushUiLog) == "function" then
    pcall(G.pushUiLog, msg)
  end
end

local function getSpectatorsAround(pos, range)
  if not (g_map and type(g_map.getSpectators) == "function") then return {} end
  local ok, list = pcall(g_map.getSpectators, pos, false, range, range)
  if ok and type(list) == "table" then return list end
  ok, list = pcall(g_map.getSpectators, pos, false)
  if ok and type(list) == "table" then return list end
  return {}
end

local function isPlayer(c)
  if not c then return false end
  if type(c.isPlayer) == "function" then
    local ok, v = pcall(c.isPlayer, c)
    if ok then return v == true end
  end
  return false
end

local function sameCreature(a, b)
  return a ~= nil and b ~= nil and tostring(a) == tostring(b)
end

local function hpPct(p)
  if not p then return 100 end
  if type(p.getHealthPercent) == "function" then
    local ok, v = pcall(p.getHealthPercent, p)
    if ok and type(v) == "number" then return v end
  end
  return 100
end

local function pauseFor(ms, reason)
  local G = _G.GiftOfLife
  if not G then return end
  local untilMs = nowMs() + (ms or 1500)
  G._panicPauseUntil = math.max(tonumber(G._panicPauseUntil) or 0, untilMs)
  G._panicReason = reason or "panic"

  -- v10a: also use shared pause API if available (for unified UI + global guard)
  if type(G.pause) == "function" then
    pcall(G.pause, "PanicGuard: " .. tostring(reason or "panic"), (ms or 1500), "panic_guard")
  end

  -- Best effort: stop chase/attack (do not crash if API missing)
  if g_game then
    if type(g_game.cancelAttack) == "function" then pcall(g_game.cancelAttack) end
    if type(g_game.setChaseMode) == "function" then pcall(g_game.setChaseMode, 0) end
  end
end

local function isPaused()
  local G = _G.GiftOfLife
  if not G then return false end
  local u = tonumber(G._panicPauseUntil) or 0
  return nowMs() < u
end

local function tick(cfg)
  if not isOnline() then return end

  local p = getPlayer()
  local pos = getPos(p)
  if not pos then return end

  local lowHp = tonumber(cfg.lowHpPct) or 35
  local pauseMs = tonumber(cfg.pauseMs) or 3500
  local scanRange = tonumber(cfg.scanRange) or 9

  if hpPct(p) <= lowHp then
    pauseFor(pauseMs, "lowhp")
    pushUi(string.format("PanicGuard: PAUSE (HP<=%d%%)", lowHp))
    return
  end

  if cfg.detectPlayers == false then return end

  local specs = getSpectatorsAround(pos, scanRange)
  for _, c in ipairs(specs) do
    if isPlayer(c) and not sameCreature(c, p) then
      pauseFor(pauseMs, "player")
      pushUi("PanicGuard: PAUSE (player on screen)")
      return
    end
  end

  -- optional: auto-clear reason after pause ends (no action needed here)
  if not isPaused() then
    local G = _G.GiftOfLife
    if G and G._panicReason then G._panicReason = nil end
  end
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
  -- Default settings
  local cfg = {
    enabled = true,
    tickMs = 250,
    pauseMs = 3500,
    scanRange = 9,
    lowHpPct = 35,
    detectPlayers = true,
  }
  -- Allow central config presets: centralCfg.addons.panic_guard.cfg
  if type(centralCfg) == "table" and type(centralCfg.addons) == "table" and type(centralCfg.addons.panic_guard) == "table" then
    cfg = deepMerge(cfg, centralCfg.addons.panic_guard.cfg or {})
  end
  return cfg
end

function A.init(entry, centralCfg)
  _loadToken = _loadToken + 1
  local token = _loadToken

  local cfg = resolveCfg(centralCfg)
  if entry and type(entry) == "table" then
    cfg = deepMerge(cfg, entry.cfg or {})
  end

  stopEvent()
  local tickMs = math.max(50, math.min(500, tonumber(cfg.tickMs) or 250))
  _evt = scheduleTick(function()
    if token ~= _loadToken then return end
    if cfg.enabled == true then
      tick(cfg)
    end
  end, tickMs)

  safePrint("[GoL][PanicGuard] init")
end

function A.shutdown()
  stopEvent()
  _loadToken = _loadToken + 1
  safePrint("[GoL][PanicGuard] shutdown")
end

return A
