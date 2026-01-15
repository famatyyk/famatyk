-- addons/autospell_rotation.lua
-- Auto Spell Rotation + AoE Rune "best tile" helper (Gift of Life addon).
-- Client-side helper. Keep it reload-safe: implement shutdown().

local A = {}
local _enabled = false

local _evt = nil
local _hotkeysBound = false
local _loadToken = 0

local _lastSpellMs = 0
local _lastRuneMs  = 0
local _spellLast   = {} -- index -> last cast time

local function nowMs()
  if g_clock and type(g_clock.millis) == "function" then
    local ok, v = pcall(g_clock.millis)
    if ok and type(v) == "number" then return v end
  end
  return os.time() * 1000
end

local function clamp(v, a, b)
  if v < a then return a end
  if v > b then return b end
  return v
end

local function abs(x) return x < 0 and -x or x end

local function distCheb(a, b)
  return math.max(abs((a.x or 0) - (b.x or 0)), abs((a.y or 0) - (b.y or 0)))
end

local function safePrint(msg)
  if print then pcall(function() print(msg) end) end
end

local function tryDofile(paths)
  for _, p in ipairs(paths or {}) do
    if type(p) == "string" and p ~= "" then
      local ok, res = pcall(dofile, p)
      if ok then return true, res end
    end
  end
  return false, nil
end

local function deepMerge(dst, src)
  if type(dst) ~= "table" then dst = {} end
  if type(src) ~= "table" then return dst end
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" then
      dst[k] = deepMerge(dst[k], v)
    else
      dst[k] = v
    end
  end
  return dst
end

local function resolveCfg(centralCfg)
  centralCfg = centralCfg or {}
  local base = centralCfg.base or {}
  local profName = centralCfg.activeProfile
  local prof = (type(profName) == "string" and centralCfg.profiles and centralCfg.profiles[profName]) or {}

  local out = {}
  -- We only merge the spellRotation section, but allow base/profiles to override it.
  out = deepMerge(out, base.spellRotation or {})
  out = deepMerge(out, centralCfg.spellRotation or {})
  out = deepMerge(out, prof.spellRotation or {})
  return out
end

local function getPlayer()
  if not g_game or type(g_game.getLocalPlayer) ~= "function" then return nil end
  local ok, p = pcall(g_game.getLocalPlayer)
  if ok then return p end
  return nil
end

local function getPlayerPos(player)
  if not player or type(player.getPosition) ~= "function" then return nil end
  local ok, pos = pcall(player.getPosition, player)
  if ok and type(pos) == "table" then return pos end
  return nil
end

local function getHpPct(player)
  if not player then return nil end
  if type(player.getHealthPercent) == "function" then
    local ok, v = pcall(player.getHealthPercent, player)
    if ok and type(v) == "number" then return v end
  end
  if type(player.getHealth) == "function" and type(player.getMaxHealth) == "function" then
    local ok1, hp = pcall(player.getHealth, player)
    local ok2, mhp = pcall(player.getMaxHealth, player)
    if ok1 and ok2 and type(hp) == "number" and type(mhp) == "number" and mhp > 0 then
      return (hp / mhp) * 100
    end
  end
  return nil
end

local function getManaPct(player)
  if not player then return nil end
  if type(player.getManaPercent) == "function" then
    local ok, v = pcall(player.getManaPercent, player)
    if ok and type(v) == "number" then return v end
  end
  if type(player.getMana) == "function" and type(player.getMaxMana) == "function" then
    local ok1, mp = pcall(player.getMana, player)
    local ok2, mmp = pcall(player.getMaxMana, player)
    if ok1 and ok2 and type(mp) == "number" and type(mmp) == "number" and mmp > 0 then
      return (mp / mmp) * 100
    end
  end
  return nil
end

local function isOnline()
  return g_game and type(g_game.isOnline) == "function" and g_game.isOnline()
end

local function isMonster(c)
  if not c then return false end
  if type(c.isMonster) == "function" then
    local ok, v = pcall(c.isMonster, c)
    if ok then return v and true or false end
  end
  if type(c.isPlayer) == "function" then
    local ok, v = pcall(c.isPlayer, c)
    if ok and v then return false end
  end
  if type(c.isNpc) == "function" then
    local ok, v = pcall(c.isNpc, c)
    if ok and v then return false end
  end
  -- Fallback: treat unknown creatures as monsters (safe for scoring only).
  return true
end

local function getSpectators(pos, multifloor)
  if not g_map or type(g_map.getSpectators) ~= "function" then return {} end
  local ok, specs = pcall(g_map.getSpectators, pos, multifloor and true or false)
  if ok and type(specs) == "table" then return specs end
  return {}
end

local function getCreaturePos(c)
  if not c or type(c.getPosition) ~= "function" then return nil end
  local ok, p = pcall(c.getPosition, c)
  if ok and type(p) == "table" then return p end
  return nil
end

local function getTile(pos)
  if not g_map or type(g_map.getTile) ~= "function" then return nil end
  local ok, t = pcall(g_map.getTile, pos)
  if ok then return t end
  return nil
end

local function sightClear(fromPos, toPos)
  if g_map and type(g_map.isSightClear) == "function" then
    local ok, v = pcall(g_map.isSightClear, fromPos, toPos)
    if ok then return v and true or false end
  end
  return true -- fallback: unknown
end

local function inBig37(dx, dy)
  dx = abs(dx); dy = abs(dy)
  if dx > 3 or dy > 3 then return false end
  -- 37 squares mask: 7x7 minus the 12 near-corner tiles.
  if (dx == 3 and dy >= 2) or (dy == 3 and dx >= 2) then
    return false
  end
  return true
end

local function countMonsters(monsters, centerPos, spec)
  -- spec can be:
  --  * number => chebyshev radius (1 => 3x3, 2 => 5x5, 3 => 7x7)
  --  * table  => { shape = "big37" } (Tibia large AoE runes: avalanche/gfb/thunderstorm)
  local n = 0
  if type(spec) == "table" and spec.shape == "big37" then
    for _, mpos in ipairs(monsters) do
      if mpos then
        local dx = (mpos.x or 0) - (centerPos.x or 0)
        local dy = (mpos.y or 0) - (centerPos.y or 0)
        if inBig37(dx, dy) then
          n = n + 1
        end
      end
    end
    return n
  end

  local r = tonumber(spec) or 1
  for _, mpos in ipairs(monsters) do
    if mpos and distCheb(mpos, centerPos) <= r then
      n = n + 1
    end
  end
  return n
end
  end
  return n
end

local function buildMonsterPosList(playerPos, scanRange, multifloor)
  local mons = {}
  local specs = getSpectators(playerPos, multifloor)
  for _, s in ipairs(specs) do
    if isMonster(s) then
      local p = getCreaturePos(s)
      if p and p.z == playerPos.z and distCheb(p, playerPos) <= scanRange then
        table.insert(mons, p)
      end
    end
  end
  return mons
end

local function findBestAoETile(playerPos, monsters, castRange, aoeSpec, requireSight)
  local bestPos = nil
  local bestScore = 0
  local bestDist = 9999

  for dx = -castRange, castRange do
    for dy = -castRange, castRange do
      local pos = { x = playerPos.x + dx, y = playerPos.y + dy, z = playerPos.z }
      local d = math.max(abs(dx), abs(dy))
      if d <= castRange then
        local tile = getTile(pos)
        if tile then
          if (not requireSight) or sightClear(playerPos, pos) then
            local score = countMonsters(monsters, pos, aoeSpec)
            if score > bestScore then
              bestScore = score
              bestPos = pos
              bestDist = d
            elseif score == bestScore and score > 0 then
              -- tie-break: prefer closer cast
              if d < bestDist then
                bestPos = pos
                bestDist = d
              end
            end
          end
        end
      end
    end
  end

  return bestPos, bestScore
end

local function castRuneOnPos(itemId, pos)
  if not g_game then return false end
  itemId = tonumber(itemId)
  if not itemId or itemId <= 0 then return false end
  if type(pos) ~= "table" then return false end

  -- Preferred: useItemOnPosition(itemId, pos)
  if type(g_game.useItemOnPosition) == "function" then
    local ok = pcall(g_game.useItemOnPosition, itemId, pos)
    return ok
  end

  -- Alternative: useInventoryItemWith(itemId, thingOnTile)
  local tile = getTile(pos)
  if tile and type(g_game.useInventoryItemWith) == "function" then
    local thing = nil
    if type(tile.getTopUseThing) == "function" then
      local ok, v = pcall(tile.getTopUseThing, tile)
      if ok then thing = v end
    end
    if not thing and type(tile.getTopThing) == "function" then
      local ok, v = pcall(tile.getTopThing, tile)
      if ok then thing = v end
    end
    if thing then
      local ok = pcall(g_game.useInventoryItemWith, itemId, thing)
      return ok
    end
    -- last-resort: try tile itself
    local ok = pcall(g_game.useInventoryItemWith, itemId, tile)
    return ok
  end

  return false
end

local function castSpellText(text)
  if not g_game then return false end
  if type(text) ~= "string" or text == "" then return false end
  if type(g_game.talk) == "function" then
    local ok = pcall(g_game.talk, text)
    return ok
  end
  return false
end

local function sendKey(key)
  if not g_game then return false end
  if type(key) ~= "string" or key == "" then return false end
  if type(g_game.sendKey) == "function" then
    local ok = pcall(g_game.sendKey, key)
    return ok
  end
  return false
end

local function hasTarget(requireTarget)
  if not requireTarget then return true end
  if g_game and type(g_game.getAttackingCreature) == "function" then
    local ok, c = pcall(g_game.getAttackingCreature)
    if ok then return c ~= nil end
  end
  -- If API is missing, do not block.
  return true
end

local function scheduleOnce(fn, ms)
  -- Prefer delayed scheduler if available; fall back across OTClient/OTCv8 variants.
  if type(scheduleEvent) == "function" then
    local ok, ev = pcall(scheduleEvent, fn, ms)
    if ok then return ev end
  end
  if type(addEvent) == "function" then
    local ok, ev = pcall(addEvent, fn, ms)
    if ok then return ev end
    ok, ev = pcall(addEvent, fn)
    if ok then return ev end
  end
  if g_dispatcher then
    if type(g_dispatcher.scheduleEvent) == "function" then
      local ok, ev = pcall(g_dispatcher.scheduleEvent, fn, ms)
      if ok then return ev end
      ok, ev = pcall(g_dispatcher.scheduleEvent, g_dispatcher, fn, ms)
      if ok then return ev end
    end
    if type(g_dispatcher.addEvent) == "function" then
      local ok, ev = pcall(g_dispatcher.addEvent, fn)
      if ok then return ev end
      ok, ev = pcall(g_dispatcher.addEvent, g_dispatcher, fn)
      if ok then return ev end
    end
  end
  return nil
end

local function scheduleTick(fn, ms)
  if type(cycleEvent) == "function" then
    local ok, ev = pcall(cycleEvent, fn, ms)
    if ok then return ev end
  end
  local function wrap()
    fn()
    _evt = scheduleOnce(wrap, ms)
  end
  return scheduleOnce(wrap, ms)
end

local function stopEvent()
  if _evt then
    pcall(function()
      if type(removeEvent) == "function" then
        removeEvent(_evt)
      elseif type(_evt.cancel) == "function" then
        _evt:cancel()
      end
    end)
    _evt = nil
  end
end)
    _evt = nil
  end
end

local function bindHotkey(hk)
  if _hotkeysBound then return end
  if not g_keyboard or type(g_keyboard.bindKeyDown) ~= "function" then return end
  g_keyboard.bindKeyDown(hk, function()
    if _enabled then
      A.setEnabled(false)
    else
      A.setEnabled(true)
    end
  end)
  _hotkeysBound = true
end

local function unbindHotkey(hk)
  if not _hotkeysBound then return end
  if not g_keyboard or type(g_keyboard.unbindKeyDown) ~= "function" then return end
  g_keyboard.unbindKeyDown(hk)
  _hotkeysBound = false
end

function A.setEnabled(v)
  v = v and true or false
  if v == _enabled then return end
  _enabled = v
  if _enabled then
    safePrint("[GoL][Rotation] ON")
  else
    safePrint("[GoL][Rotation] OFF")
  end
end

local function tick(cfg)
  if not _enabled then return end
  if not isOnline() then return end

  local player = getPlayer()
  if not player then return end
  local ppos = getPlayerPos(player)
  if not ppos then return end

  if not hasTarget(cfg.requireTarget) then return end

  local t = nowMs()

  local scanRange = tonumber(cfg.scanRange) or (tonumber(cfg.castRange) or 7)
  scanRange = clamp(scanRange, 1, 12)
  local castRange = clamp(tonumber(cfg.castRange) or 7, 1, 10)

  local monsters = buildMonsterPosList(ppos, scanRange, cfg.multifloor)

  -- 1) AoE runes (best tile)
  if cfg.runes and cfg.runes.enabled ~= false and (t - _lastRuneMs) >= (tonumber(cfg.runeCooldownMs) or 900) then
    local best = nil
    local bestScore = 0
    local bestRune = nil

    local list = cfg.runes.list or {}
    for _, r in ipairs(list) do
      local itemId = tonumber(r.itemId)
      local minT = tonumber(r.minTargets) or 2
      local requireSight = (r.requireSight == true) or (cfg.requireSight == true)

      -- AoE spec: prefer exact large-rune mask when requested.
      local aoeSpec = nil
      if r.shape == "big37" then
        aoeSpec = { shape = "big37" }
      else
        local aoeR = tonumber(r.aoeRadius) or tonumber(cfg.aoeDefaultRadius) or 1
        aoeR = clamp(aoeR, 0, 6)
        aoeSpec = aoeR
      end

      if itemId and itemId > 0 then
        local pos, score = findBestAoETile(ppos, monsters, castRange, aoeSpec, requireSight)
        if score > bestScore then
          bestScore = score
          best = pos
          bestRune = r
        end
      end
    end

    if bestRune and best and bestScore >= (tonumber(bestRune.minTargets) or 2) then
      local ok = castRuneOnPos(bestRune.itemId, best)
      if ok then
        _lastRuneMs = t
        return
      end
    end
  end

  -- 2) Spell rotation (simple priority list)
  if cfg.spells and type(cfg.spells) == "table" and (t - _lastSpellMs) >= (tonumber(cfg.spellCooldownMs) or 900) then
    local hp = getHpPct(player)
    local mp = getManaPct(player)
    local mcount = #monsters

    for i, s in ipairs(cfg.spells) do
      if s and s.enabled ~= false then
        local cd = tonumber(s.cooldownMs) or 1200
        local last = tonumber(_spellLast[i]) or 0
        if (t - last) >= cd then
          local minMana = tonumber(s.minManaPct)
          local maxHp   = tonumber(s.maxHpPct)
          local minTargets = tonumber(s.minTargets)

          if (minMana == nil or (mp ~= nil and mp >= minMana)) and
             (maxHp == nil or (hp ~= nil and hp <= maxHp)) and
             (minTargets == nil or mcount >= minTargets) then

            local ok = false
            if type(s.text) == "string" and s.text ~= "" then
              ok = castSpellText(s.text)
            elseif type(s.hotkey) == "string" and s.hotkey ~= "" then
              ok = sendKey(s.hotkey)
            end

            if ok then
              _spellLast[i] = t
              _lastSpellMs = t
              return
            end
          end
        end
      end
    end
  end
end

function A.init(entry, centralCfg)
  -- entry: addons.autospell_rotation
  _loadToken = _loadToken + 1
  local token = _loadToken

  local cfg = resolveCfg(centralCfg)
  if entry and type(entry) == "table" then
    -- allow per-addon override
    cfg = deepMerge(cfg, entry.cfg or {})
  end

  -- default enabled flag comes from cfg.enabled; addon entry.enabled just loads addon.
  _enabled = (cfg.enabled == true)

  if cfg.hotkeyToggle and type(cfg.hotkeyToggle) == "string" and cfg.hotkeyToggle ~= "" then
    bindHotkey(cfg.hotkeyToggle)
  end

  local tickMs = clamp(tonumber(cfg.tickMs) or 120, 25, 500)

  stopEvent()
  _evt = scheduleTick(function()
    if token ~= _loadToken then return end
    tick(cfg)
  end, tickMs)

  safePrint("[GoL][Rotation] init (loaded addon)")
end

function A.shutdown()
  if _evt then
    stopEvent()
  end
  _enabled = false
  _spellLast = {}
  _lastSpellMs = 0
  _lastRuneMs = 0

  -- Unbind hotkey (best-effort: read current config)
  local ok, central = tryDofile({ "config.lua", "gift_of_life/config.lua", "modules/gift_of_life/config.lua" })
  if ok and type(central) == "table" then
    local cfg = resolveCfg(central)
    if cfg.hotkeyToggle then
      unbindHotkey(cfg.hotkeyToggle)
    end
  end

  safePrint("[GoL][Rotation] shutdown")
end

return A
