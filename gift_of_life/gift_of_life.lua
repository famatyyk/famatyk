
-- [[ GoL bootstrap: safePrint fallback (AAH/log helpers) ]]
-- Some builds do not provide safePrint; define a safe, no-crash logger.
if type(_G.safePrint) ~= 'function' then
  function _G.safePrint(...)
    local parts = {}
    for i = 1, select('#', ...) do
      parts[#parts + 1] = tostring(select(i, ...))
    end
    local msg = table.concat(parts, ' ')
    -- Use exactly one sink to avoid duplicated lines in terminal console.
    if _G.g_logger and type(_G.g_logger.info) == 'function' then
      pcall(function() _G.g_logger.info(msg) end)
    else
      pcall(function() print(msg) end)
    end
  end
end

-- gift_of_life.lua
-- Auto-heal + mana potion with a simple UI. English comments only.

-- ========== GLOBAL SINGLETON ==========
_G.GiftOfLife = _G.GiftOfLife or {}
local G = _G.GiftOfLife


-- UI lifetime: when true, UI should not auto-spawn; user explicitly re-opens it.
G._uiSuppressed = (G._uiSuppressed == true)
-- Reload token: used to ignore stale addEvent callbacks after a quick reload.
G._loadToken = (tonumber(G._loadToken) or 0) + 1
local LOAD_TOKEN = G._loadToken

-- Reload sequence: init.lua increments this before each dofile() to invalidate stale scheduled callbacks.
G._reloadSeq = (tonumber(_G.GoL_ReloadSeq) or 0)
local LOAD_SEQ = G._reloadSeq

-- v12-pro: closing the window (X) hides it only for the current session.
-- When the module is loaded again via init.lua/dofile, always allow the window to spawn.
G._uiSuppressed = false


-- g_settings keys (v10m): backup persistence for window geometry.
local GSET_WIN_POS_KEY  = "gift_of_life.window-pos"
local GSET_WIN_SIZE_KEY = "gift_of_life.window-size"

-- ========== DEFAULT CONFIG ==========
local DEFAULT_CFG = {
  -- Mana potions
  manaPotionIds = { 238, 237, 268 },
  manaStartPct = 35,
  manaStopPct  = 80,
  manaStartMana = nil,
  manaStopMana  = nil,

  -- Master toggles (initial state)
  healEnabled = true,
  manaEnabled = true,
  
  -- Dev tools (Dbg/Catalog/Editor). When disabled, dev UI stays hidden and dev modules are not loaded.
  devTools = { enabled = true },

  -- Loot
  lootEnabled = false,
  loot = {
    mode = "list",
    itemIds = {},
    ignoreIds = {},
    goldIds = { 3031, 3035, 3043 },
    stackIds = {},
    mainBpNth = 1,
    lootBpNth = 2,
    stackBpNth = 3,
    sourcePolicy = "lastNonBp",
    sourceNth = 4,
    skipNameContains = { "backpack", "bag", "pouch", "quiver" },
    moveCooldownMs = 120,
    maxMovesPerTick = 1,
    minCap = 150,
    lowCapBehavior = "skip",
    openNextOnFull = true,

    openNextCooldownMs = 800,
    openWaitMs = 650,
    sourcePinMs = 6000,
    stackIntoExisting = true,

    goldStackMax = 200,
    stackMax = 100,

    coinChangeEnabled = true,
    coinChangeThreshold = 200,
    coinChangeCooldownMs = 800,
    coinChangeMaxUsesPerTick = 1,

    sorterEnabled = true,
    sorterCooldownMs = 600,
    sorterMaxMovesPerTick = 2,
  },


  -- Healing thresholds (HP percent)
  hpExuraPct     = 88,
  hpExuraGranPct = 70,
  hpExuraVitaPct = 52,

  -- Spells to cast
  spellExura     = "exura",
  spellExuraGran = "exura gran",
  spellExuraVita = "exura vita",

  -- Timers
  tickMs           = 120,
  spellCooldownMs  = 850,
  potionCooldownMs = 900,

  -- Debug
  debug = false,
  potionLogThrottleMs = 2500,

  -- Out-of-potions backoff
  noPotRetryMs = 7000,
  noPotLogThrottleMs = 10000,

  -- Optional jitter on potion cooldown (table {minMs, maxMs})
  potionCooldownJitterMs = nil,

  -- If true, allow plain g_game.use(item) as a last resort
  allowDirectUse = false,

  -- HUD
  hudEnabled = true,
  hudUpdateMs = 250,
  ui = {
    maxLogLines = 8,
    hotkeysEnabled = true,
  },

}

-- ========== LOAD CONFIG ==========
local function deepFill(dst, src)
  for k, v in pairs(src) do
    if dst[k] == nil then
      if type(v) == "table" then
        local t = {}
        deepFill(t, v)
        dst[k] = t
      else
        dst[k] = v
      end
    else
      if type(dst[k]) == "table" and type(v) == "table" then
        deepFill(dst[k], v)
      end
    end
  end
end

local CFG = {}
deepFill(CFG, DEFAULT_CFG)
do
  local ok, cfg = pcall(dofile, "gift_of_life_config.lua")
  if not ok then ok, cfg = pcall(dofile, "gift_of_life/gift_of_life_config.lua") end
  if not ok then ok, cfg = pcall(dofile, "modules/gift_of_life/gift_of_life_config.lua") end
  if ok and type(cfg) == "table" then
    deepFill(cfg, DEFAULT_CFG)
    CFG = cfg
  end
end

-- Track selected state path from config shim (gift_of_life_config.lua).
-- This helps debug save/load issues across client forks.
if type(_G.GoLStatePath) == "string" and _G.GoLStatePath ~= "" then
  G._statePath = _G.GoLStatePath
end

-- ========== UTIL ==========
local function nowMs()
  if g_clock and g_clock.millis then return g_clock.millis() end
  return math.floor(os.clock() * 1000)
end


-- Normalize id lists (loot / no-loot) to a plain array of unique numeric IDs.
-- Accepts both array-style {123,456} and set-style {[123]=true, [456]=true}.
local function _golNormalizeIdList(list)
  if type(list) ~= "table" then return {} end
  local out, seen = {}, {}
  for _, v in ipairs(list) do
    local id = tonumber(v)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      out[#out+1] = id
    end
  end
  for k, v in pairs(list) do
    if v == true or v == 1 then
      local id = tonumber(k)
      if id and id > 0 and not seen[id] then
        seen[id] = true
        out[#out+1] = id
      end
    end
  end
  return out
end



-- ========== UI STATE (v10b) ==========
G.ui = (type(G.ui) == "table") and G.ui or {}

-- Prefer persisted state overlay if present.
if type(CFG.ui) == "table" and CFG.ui.debugVisible ~= nil then
  G.ui.debugVisible = (CFG.ui.debugVisible == true)
elseif G.ui.debugVisible == nil then
  G.ui.debugVisible = false
end

G._startMs = G._startMs or nowMs()
G._telemetryNextMs = G._telemetryNextMs or 0
G.lastAction = G.lastAction or ""
G.lastActionAtMs = G.lastActionAtMs or 0

-- ========== PAUSE MANAGER (v10d) ==========
-- One shared pause mechanism that all automation respects.
-- Key features:
--   * pause stack (multiple sources can pause at once)
--   * priority support
--   * UI shows reason + remaining seconds + (optional) count
-- Compatibility: still reads legacy G._panicPauseUntil (from Panic Guard v9).

G._pauseStack = (type(G._pauseStack) == "table") and G._pauseStack or {}

-- Migrate old single pause state (from earlier v10a builds) into stack.
do
  local p = G._pause
  if type(p) == "table" then
    local t = nowMs()
    local u = tonumber(p.untilMs) or 0
    if u > t then
      local src = tostring(p.source or "legacy")
      G._pauseStack[src] = {
        untilMs = u,
        reason = tostring(p.reason or "paused"),
        source = src,
        priority = tonumber(p.priority) or 0,
        sinceMs = tonumber(p.sinceMs) or t,
      }
    end
  end
  -- Keep a small legacy container to avoid nil indexing in older code.
  G._pause = { untilMs = 0, reason = nil, source = nil, sinceMs = 0 }
end

-- Pause the system for ms milliseconds.
-- source: string key (e.g. "panic_guard", "manual", "loot")
-- priority: number (higher wins when multiple pauses overlap)
function G.pause(reason, ms, source, priority)
  local t = nowMs()
  local dur = tonumber(ms) or 0
  if dur < 0 then dur = 0 end
  local untilMs = t + dur

  local src = tostring(source or "unknown")
  local stack = G._pauseStack
  if type(stack) ~= "table" then
    stack = {}
    G._pauseStack = stack
  end

  local e = stack[src]
  if type(e) ~= "table" then e = {} end

  local curUntil = tonumber(e.untilMs) or 0
  if untilMs >= curUntil then
    e.untilMs = untilMs
  end
  e.reason = tostring(reason or e.reason or "paused")
  e.source = src
  e.priority = tonumber(priority) or tonumber(e.priority) or 0
  if (tonumber(e.sinceMs) or 0) <= 0 then
    e.sinceMs = t
  end

  stack[src] = e
  return e.untilMs
end

-- Clear pause.
-- If source is nil: clears ALL pause sources.
function G.clearPause(source)
  local stack = G._pauseStack
  if type(stack) ~= "table" then return end
  if source == nil then
    for k in pairs(stack) do stack[k] = nil end
    return
  end
  stack[tostring(source)] = nil
end

local function legacyPanicInfo(now)
  local u = tonumber(G._panicPauseUntil) or 0
  if now < u then
    local r = tostring(G._panicReason or "panic")
    if r == "lowhp" then r = "Panic: low HP"
    elseif r == "player" then r = "Panic: player on screen"
    else r = "Panic: " .. r end
    return { untilMs = u, reason = r, source = "panic_guard" }
  end
  return nil
end

function G.getPauseInfo()
  local t = nowMs()

  local bestUntil = 0
  local bestReason, bestSource = nil, nil
  local bestPriority = -math.huge
  local count = 0

  -- Pause stack
  local stack = G._pauseStack
  if type(stack) == "table" then
    for src, e in pairs(stack) do
      if type(e) == "table" then
        local u = tonumber(e.untilMs) or 0
        if t < u then
          count = count + 1
          local pr = tonumber(e.priority) or 0
          -- Pick by priority first, then by remaining time.
          if (pr > bestPriority) or (pr == bestPriority and u > bestUntil) then
            bestPriority = pr
            bestUntil = u
            bestReason = e.reason
            bestSource = src
          end
        else
          -- cleanup expired entries
          stack[src] = nil
        end
      end
    end
  end

  -- Legacy panic guard pause (only if it's stronger than stack or stack doesn't have it)
  local lp = legacyPanicInfo(t)
  if lp then
    local lpUntil = tonumber(lp.untilMs) or 0
    local stackPanic = nil
    if type(stack) == "table" then
      stackPanic = stack["panic_guard"]
      if type(stackPanic) == "table" and t < (tonumber(stackPanic.untilMs) or 0) then
        -- already counted in stack
        stackPanic = true
      else
        stackPanic = nil
      end
    end

    if (not stackPanic) and t < lpUntil then
      count = count + 1
    end

    if lpUntil > bestUntil then
      bestUntil = lpUntil
      bestReason = lp.reason
      bestSource = lp.source
      bestPriority = math.max(bestPriority, 100)
    end
  end

  local remaining = bestUntil - t
  if remaining < 0 then remaining = 0 end

  return {
    paused = remaining > 0,
    remainingMs = remaining,
    untilMs = bestUntil,
    reason = bestReason,
    source = bestSource,
    count = count,
    nowMs = t,
  }
end

function G.isPaused()
  local info = G.getPauseInfo and G.getPauseInfo() or nil
  return info and info.paused == true or false
end


local function callAny(obj, method, ...)
  if not obj then return false, nil end
  local fn = obj[method]
  if type(fn) ~= "function" then return false, nil end

  local ok, res = pcall(fn, ...)
  if ok then return true, res end

  ok, res = pcall(fn, obj, ...)
  if ok then return true, res end

  return false, nil
end

local function normalizePct(v)
  if type(v) ~= "number" then return 0 end
  -- guard against NaN/inf
  if v ~= v or v == math.huge or v == -math.huge then return 0 end
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  return math.floor(v + 0.5)
end
local function getWidgetId(w)
  if not w then return nil end
  local ok, id = callAny(w, "getId")
  if ok and type(id) == "string" and id ~= "" then return id end
  -- some builds expose id as a field
  local fid = rawget(w, "id")
  if type(fid) == "string" and fid ~= "" then return fid end
  return nil
end

local function findChildByIdDeep(root, id, depth)
  if not root or not id then return nil end
  depth = (depth or 0) + 1
  if depth > 64 then return nil end

  if getWidgetId(root) == id then return root end

  local ok, children = callAny(root, "getChildren")
  if not ok or type(children) ~= "table" then return nil end

  for i = 1, #children do
    local found = findChildByIdDeep(children[i], id, depth)
    if found then return found end
  end

  return nil
end

local function getUiChild(win, id)
  if not win then return nil end
  local ok, w = callAny(win, "getChildById", id)
  if ok and w then return w end
  ok, w = callAny(win, "recursiveGetChildById", id)
  if ok and w then return w end
  w = findChildByIdDeep(win, id, 0)
  if w then return w end
  return nil
end


local function safeSetTooltip(w, text)
  if not w then return end
  if type(text) ~= "string" or text == "" then return end
  if type(w.setTooltip) == "function" then
    pcall(w.setTooltip, w, text)
    return
  end
  if type(w.setTooltipText) == "function" then
    pcall(w.setTooltipText, w, text)
    return
  end
end

-- forward declaration (needed because several functions call ensureWindow before it's defined)
local ensureWindow
-- forward declaration (used in stopLoop before it's defined)
local updateQuickButtons
-- forward declaration (pause status label)
local updatePauseStatus
-- forward declaration (hotkeys rebind)
local bindHotkeys
local unbindHotkeys

-- ========== MINI ACTION LOG (in-window) ==========
G._logLines = G._logLines or {}

local function _syncUiLog()
  local win = G._window
  if not win then return end
  local lab = getUiChild(win, "actionLogText")
  if not lab then return end

  local txt = table.concat(G._logLines, "\n")
  local stickToBottom = true
  local sb = getUiChild(win, "actionLogScroll")
  if sb and sb.getValue and sb.getMaximum then
    local okV, v = pcall(sb.getValue, sb)
    local okM, mx = pcall(sb.getMaximum, sb)
    if okV and okM and type(v) == "number" and type(mx) == "number" then
      stickToBottom = (v >= mx - 1)
    end
  end

  pcall(function() lab:setText(txt) end)
  if stickToBottom and sb and sb.setValue and sb.getMaximum then
    pcall(function() sb:setValue(sb:getMaximum()) end)
  end
end

local function pushUiLog(msg)
  if type(msg) ~= "string" then msg = tostring(msg) end

  local maxLines = 60
  if CFG and CFG.ui and tonumber(CFG.ui.maxLogLines) then
    maxLines = tonumber(CFG.ui.maxLogLines)
  end

  local t = (os.date and os.date("%H:%M:%S")) or ""
  local line = (t ~= "" and (t .. " " .. msg) or msg)

  -- Telemetry last action
  G.lastAction = msg
  G.lastActionAtMs = nowMs()

  table.insert(G._logLines, line)
  while #G._logLines > maxLines do table.remove(G._logLines, 1) end

  if G._window then
    _syncUiLog()
  end
end

-- Forward declarations (needed because applyWindowChrome uses these before definitions).
local getWinSize
local resizeWin
local getWinPos
local setWinPos
local requestSaveConfig

-- v10l helper: robust "is widget still valid?" check (fork-safe).
-- OTClient UIWidget exposes isDestroyed() in C++ bindings. (Some forks keep it.)
local function widgetAlive(w)
  if not w then return false end
  if type(w.isDestroyed) == "function" then
    local ok, destroyed = pcall(w.isDestroyed, w)
    if ok then return destroyed == false end
  end

  -- fallback: if it has an id and calling doesn't explode, treat as alive
  if type(w.getId) == "function" then
    local ok = pcall(w.getId, w)
    return ok
  end
  return true
end

local function safeTrackWidget(w, label)
  if not w then return end
  if _G.GoL and _G.GoL.LeakGuardPP and type(_G.GoL.LeakGuardPP.trackWidget) == "function" then
    pcall(_G.GoL.LeakGuardPP.trackWidget, w, label)
  end
  if _G.GoLLeakGuard and type(_G.GoLLeakGuard.track) == "function" then
    pcall(_G.GoLLeakGuard.track, w)
  end
end

local function safeTrackEvent(ev, label)
  if _G.GoL and _G.GoL.LeakGuardPP and type(_G.GoL.LeakGuardPP.trackEvent) == "function" then
    pcall(_G.GoL.LeakGuardPP.trackEvent, ev, label)
  end
  return ev
end

local function safeDestroyWidget(w, why)
  if not w then return end
  if _G.GoL and _G.GoL.LeakGuardPP and type(_G.GoL.LeakGuardPP.destroyWidget) == "function" then
    pcall(_G.GoL.LeakGuardPP.destroyWidget, w, why)
    return
  end
  pcall(function() if type(w.destroyChildren) == "function" then w:destroyChildren() end end)
  pcall(function() if type(w.destroy) == "function" then w:destroy() end end)
end

local function applyWindowChrome(win)
  -- Do not create UI here; only apply chrome if window already exists.
  if not win then win = (widgetAlive(G._window) and G._window) or nil end
  if not win then return end

  -- Profile picker (manual): open it again from main window.
  do
      local pb = getUiChild(win, "profileChangeButton")
      if pb then
        pb.onClick = function()
          if type(CFG.ui) ~= "table" then CFG.ui = {} end
          CFG.ui.firstRunDone = false
          if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end
          pcall(function() showProfilePickerIfFirstRun() end)
        end
      end
  end

  -- v10l: try to enable built-in resizing if supported by this client fork.
  pcall(function() callAny(win, "setResizable", true) end)
  pcall(function() callAny(win, "setResizeable", true) end)
  pcall(function() win.resizable = true end)

  -- v10l: restore persisted window geometry (size/position) once per instance.
  if G._appliedWinState ~= win then
    G._appliedWinState = win

    local appliedSize, appliedPos = false, false

    if type(CFG.ui) == "table" and type(CFG.ui.window) == "table" then
      local st = CFG.ui.window
      local w = tonumber(st.w)
      local h = tonumber(st.h)
      if w and h and w > 50 and h > 50 then
        appliedSize = true
        pcall(function() resizeWin(win, w, h) end)
      end

      local x = tonumber(st.x)
      local y = tonumber(st.y)
      if x and y then
        appliedPos = true
        pcall(function() setWinPos(win, x, y) end)
      end

      if st.locked ~= nil then G.uiLocked = (st.locked == true) end
      if st.minimized ~= nil then G.uiMinimized = (st.minimized == true) end
    end

    -- v10m: fallback window geometry from g_settings (backup) if state file has no geometry yet.
    if g_settings then
      if (not appliedSize) and type(g_settings.getSize) == "function" then
        local okS, sz = pcall(g_settings.getSize, GSET_WIN_SIZE_KEY, { width = 0, height = 0 })
        if okS and type(sz) == "table" then
          local ww = tonumber(sz.width)
          local hh = tonumber(sz.height)
          if ww and hh and ww > 50 and hh > 50 then
            pcall(function() resizeWin(win, ww, hh) end)
          end
        end
      end

      if (not appliedPos) and type(g_settings.getPoint) == "function" then
        local okP, pt = pcall(g_settings.getPoint, GSET_WIN_POS_KEY, { x = -1, y = -1 })
        if okP and type(pt) == "table" then
          local xx = tonumber(pt.x)
          local yy = tonumber(pt.y)
          if xx and yy and xx >= 0 and yy >= 0 then
            pcall(function() setWinPos(win, xx, yy) end)
          end
        end
      end
    end

	    -- v12-pro: clamp window to visible area (prevents "lost" window after resolution changes
	    -- or bad persisted X/Y).
	    pcall(function()
	      local sw, sh = nil, nil
	      if g_window and type(g_window.getSize) == "function" then
	        local okS, s = pcall(g_window.getSize)
	        if okS and type(s) == "table" then
	          sw = tonumber(s.width or s.w or s[1])
	          sh = tonumber(s.height or s.h or s[2])
	        end
	      end
	      if not sw or not sh then
	        local root = (g_ui and g_ui.getRootWidget) and g_ui.getRootWidget() or nil
	        if root then
	          sw = sw or (type(root.getWidth) == "function" and root:getWidth() or nil)
	          sh = sh or (type(root.getHeight) == "function" and root:getHeight() or nil)
	        end
	      end
	      if type(sw) ~= "number" or type(sh) ~= "number" then return end

	      local w, h = getWinSize(win)
	      local x, y = getWinPos(win)
	      if type(w) ~= "number" or type(h) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then return end

	      local maxX = math.max(0, sw - w)
	      local maxY = math.max(0, sh - h)
	      local nx = math.min(math.max(0, x), maxX)
	      local ny = math.min(math.max(0, y), maxY)
	      if nx ~= x or ny ~= y then
	        setWinPos(win, nx, ny)
	      end
	    end)

  end

  -- v10l: resize grip (fork-proof). If the widget exists in .otui, bind handlers here.
  local grip = getUiChild(win, "resizeGrip")
  if grip and not (grip._golBound == true) then
    grip._golBound = true

    local startMouse = nil
    local startW, startH = nil, nil
    local minW = 220
    local minH = 260

    grip.onMousePress = function(_, mousePos, button)
      if G.uiLocked == true then return true end
      startMouse = mousePos
      startW, startH = getWinSize(win)
      return true
    end

    grip.onMouseMove = function(_, mousePos, _)
      if not startMouse or not startW or not startH then return true end
      if G.uiLocked == true then return true end
      if not mousePos then return true end

      local dx = tonumber(mousePos.x or (mousePos[1])) or 0
      local dy = tonumber(mousePos.y or (mousePos[2])) or 0
      local sx = tonumber(startMouse.x or (startMouse[1])) or 0
      local sy = tonumber(startMouse.y or (startMouse[2])) or 0

      local nw = math.max(minW, startW + (dx - sx))
      local nh = math.max(minH, startH + (dy - sy))
      pcall(function() resizeWin(win, nw, nh) end)
      return true
    end

    grip.onMouseRelease = function()
      startMouse = nil
      startW, startH = nil, nil
      -- update persisted UI overlay ASAP
      if requestSaveConfig then pcall(requestSaveConfig) end
      return true
    end
  end

  -- v10l: poll window geometry and persist (debounced) when it changes.
  if scheduleEvent and not G._winPollEv then
    G._lastWinGeom = G._lastWinGeom or { x = nil, y = nil, w = nil, h = nil }

    local function poll()
      if not widgetAlive(G._window) then
        G._winPollEv = nil
        return
      end

      local w, h = getWinSize(G._window)
      local x, y = getWinPos(G._window)

      local changed = false
      if type(w) == "number" and type(h) == "number" then
        if G._lastWinGeom.w ~= w or G._lastWinGeom.h ~= h then
          G._lastWinGeom.w = w
          G._lastWinGeom.h = h
          changed = true
        end
      end
      if type(x) == "number" and type(y) == "number" then
        if G._lastWinGeom.x ~= x or G._lastWinGeom.y ~= y then
          G._lastWinGeom.x = x
          G._lastWinGeom.y = y
          changed = true
        end
      end

      if changed then
        CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
        CFG.ui.window = (type(CFG.ui.window) == "table") and CFG.ui.window or {}
        if type(x) == "number" and type(y) == "number" then
          CFG.ui.window.x = x
          CFG.ui.window.y = y
        end
        if type(w) == "number" and type(h) == "number" then
          CFG.ui.window.w = w
          CFG.ui.window.h = h
        end
        CFG.ui.window.locked = (G.uiLocked == true)
        CFG.ui.window.minimized = (G.uiMinimized == true)

        if requestSaveConfig then pcall(requestSaveConfig) end
      end

      -- keep polling (fork-safe; scheduleEvent is one-shot on most OTClient forks)
      G._winPollEv = safeTrackEvent(scheduleEvent(poll, 700), "GoL.winPoll")
    end

    G._winPollEv = safeTrackEvent(scheduleEvent(poll, 700), "GoL.winPoll")
  end


  local function _golCloseMainWindow()
    -- Do not destroy on user-close; some OTClient forks can keep mouse capture on destroy.
    -- We hide and suppress auto-spawn; reload-purge will destroy it safely.
    G._uiSuppressed = true
    pcall(function() win:hide() end)
    return true
  end

  local closeBtn = getUiChild(win, "closeButton")
  if closeBtn then
    closeBtn.onClick = _golCloseMainWindow
  end

  pcall(function()
    win.onClose = _golCloseMainWindow
  end)


  local minBtn = getUiChild(win, "minimizeButton")
  local content = getUiChild(win, "contentPanel")
  if minBtn and content then
    local function setMinimized(state)
      state = (state == true)
      G._minimized = state

      -- Capture window size before the first minimize.
      if not G._minSavedSize and getWinSize then
        local ok, sz = pcall(getWinSize, win)
        if ok and type(sz) == "table" then G._minSavedSize = sz end
      end

      if state then
        pcall(function() content:hide() end)
        pcall(function() content:setEnabled(false) end)
        pcall(function() minBtn:setText("+") end)

        -- Shrink height to titlebar-ish. Width stays.
        local okW, w = pcall(function() return win:getWidth() end)
        if okW and type(w) == "number" then
          pcall(function() win:setWidth(w) end)
        end
        pcall(function() win:setHeight(44) end)
      else
        pcall(function() content:show() end)
        pcall(function() content:setEnabled(true) end)
        pcall(function() minBtn:setText("-") end)

        local sz = G._minSavedSize
        if type(sz) == "table" then
          if sz.w then pcall(function() win:setWidth(sz.w) end) end
          if sz.h then pcall(function() win:setHeight(sz.h) end) end
        end

        -- Rebind UI clicks after restore (other modules can override handlers).
        if scheduleEvent and type(G._rebindUi) == "function" then
          scheduleEvent(function()
            pcall(G._rebindUi)
            if type(G.refreshUi) == "function" then pcall(G.refreshUi) end
          end, 60)
        end
      end
    end

    local function toggleMin()
      setMinimized(not (G._minimized == true))
    end

    -- Our minimize click handler (watchdog will keep it installed).
    local function minClick()
      toggleMin()
      if requestSaveConfig then pcall(requestSaveConfig) end
      return true
    end
    G._minBtnFn = minClick
    minBtn.onClick = minClick

    -- Watchdog: re-apply onClick periodically (DivinePremium / other UI hooks can overwrite handlers).
    if scheduleEvent then
      if removeEvent and G._minBtnWatchEv then pcall(removeEvent, G._minBtnWatchEv) end
      local function watch()
        local w = ensureWindow()
        if not w then return end
        local b = getUiChild(w, "minimizeButton")
        if b and b.onClick ~= G._minBtnFn then
          b.onClick = G._minBtnFn
        end
        -- If we're minimized and content got re-shown by someone, re-hide it.
        if G._minimized == true then
          local c = getUiChild(w, "contentPanel")
          if c and c:isVisible() then pcall(function() c:hide() end) end
        end
        G._minBtnWatchEv = safeTrackEvent(scheduleEvent(watch, 900), "GoL.minBtnWatch")
      end
      G._minBtnWatchEv = safeTrackEvent(scheduleEvent(watch, 900), "GoL.minBtnWatch")
    end

    -- Initial glyph
    pcall(function() minBtn:setText((G._minimized == true) and "+" or "-") end)
  end
    local lockBtn = getUiChild(win, "lockButton")
  if lockBtn then
    lockBtn.onClick = function()
      G.uiLocked = not (G.uiLocked == true)
      if requestSaveConfig then pcall(requestSaveConfig) end
      pcall(function() lockBtn:setOn(G.uiLocked) end)

      local allowMove = not G.uiLocked
      callAny(win, "setDraggable", allowMove)
      callAny(win, "setMoveable", allowMove)
      callAny(win, "setMovable", allowMove)
      pcall(function() win.draggable = allowMove end)
      pcall(function() win.moveable = allowMove end)
    end
  end

  -- Apply current states (after reload)
  if lockBtn then
    pcall(function() lockBtn:setOn(G.uiLocked == true) end)
  end
  if minBtn and content then
    pcall(function() minBtn:setOn(G.uiMinimized == true) end)
    if G.uiMinimized == true then
      pcall(function() content:hide() end)
      local w, _ = getWinSize(win)
      resizeWin(win, w, 44)
    end
  end
end

getWinSize = function(win)
  -- Return current window size (w,h). Support multiple OTClient structs:
  -- {width,height} or {w,h} or array-like { [1]=w, [2]=h } or (as last resort) {x,y}.
  local function parseSize(s)
    if type(s) ~= "table" then return nil end
    local w = s.width or s.w or s[1]
    local h = s.height or s.h or s[2]
    w = tonumber(w)
    h = tonumber(h)
    if w and h and w > 0 and h > 0 then return w, h end
    -- Some builds expose Size as {x,y}
    w = tonumber(s.x)
    h = tonumber(s.y)
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
  end

  local ok, s = callAny(win, "getSize")
  if ok then
    local w, h = parseSize(s)
    if w then return w, h end
  end

  ok, s = callAny(win, "getRect")
  if ok and type(s) == "table" then
    -- Rect might have width/height, prefer those.
    local w = tonumber(s.width)
    local h = tonumber(s.height)
    if w and h and w > 0 and h > 0 then return w, h end
    -- Fallback: try generic parse
    w, h = parseSize(s)
    if w then return w, h end
  end

  return 270, 480
end

local function _golExtractXY(p)
  if type(p) == "table" then
    local x = p.x or p[1]
    local y = p.y or p[2]
    x = tonumber(x); y = tonumber(y)
    if x and y then return x, y end
  end
  -- try common userdata/objects: p:getX(), p:getY()
  local okX, x = callAny(p, "getX")
  local okY, y = callAny(p, "getY")
  if okX and okY then
    x = tonumber(x); y = tonumber(y)
    if x and y then return x, y end
  end
  return nil, nil
end

getWinPos = function(win)
  if not win then return nil, nil end

  -- Prefer getPosition() / getRect() when available.
  local okP, p = callAny(win, "getPosition")
  if okP then
    local x, y = _golExtractXY(p)
    if x and y then return x, y end
  end

  local okR, r = callAny(win, "getRect")
  if okR then
    if type(r) == "table" then
      local x = tonumber(r.x or r.left or r[1])
      local y = tonumber(r.y or r.top or r[2])
      if x and y then return x, y end
    else
      -- some rect objects expose getters
      local okX, x = callAny(r, "x")
      local okY, y = callAny(r, "y")
      if okX and okY then
        x = tonumber(x); y = tonumber(y)
        if x and y then return x, y end
      end
    end
  end

  local okX, x = callAny(win, "getX")
  local okY, y = callAny(win, "getY")
  if okX and okY then
    x = tonumber(x); y = tonumber(y)
    if x and y then return x, y end
  end

  return nil, nil
end

setWinPos = function(win, x, y)
  if not win then return false end
  x = tonumber(x); y = tonumber(y)
  if not x or not y then return false end

  -- common APIs
  local ok = callAny(win, "setPosition", { x = x, y = y })
  if ok then return true end
  ok = callAny(win, "setPosition", { left = x, top = y })
  if ok then return true end
  ok = callAny(win, "move", { x = x, y = y })
  if ok then return true end

  -- fallback: setX/setY
  local ok1 = callAny(win, "setX", x)
  local ok2 = callAny(win, "setY", y)
  if ok1 and ok2 then return true end

  return false
end

resizeWin = function(win, w, h)
  -- Resize window using multiple possible APIs.
  if not win then return false end
  w = tonumber(w) or 0
  h = tonumber(h) or 0
  if w <= 0 or h <= 0 then return false end

  -- Try common signatures first.
  local ok = callAny(win, "resize", { width = w, height = h })
  if ok then return true end
  ok = callAny(win, "resize", { w = w, h = h })
  if ok then return true end
  ok = callAny(win, "resize", { x = w, y = h })
  if ok then return true end
  ok = callAny(win, "resize", w, h)
  if ok then return true end

  ok = callAny(win, "setSize", { width = w, height = h })
  if ok then return true end
  ok = callAny(win, "setSize", { w = w, h = h })
  if ok then return true end
  ok = callAny(win, "setSize", { x = w, y = h })
  if ok then return true end
  ok = callAny(win, "setSize", w, h)
  if ok then return true end

  -- Last resort: setWidth/setHeight if available.
  ok = callAny(win, "setWidth", w)
  local ok2 = callAny(win, "setHeight", h)
  if ok or ok2 then return true end

  return false
end

local function normalizePct(v)
  if type(v) ~= "number" then return 0 end
  if v >= 0 and v <= 1.01 then v = v * 100 end
  if v < 0 then v = 0 end
  if v > 100 then v = 100 end
  return v
end

local function widgetAlive(w)
  if not w then return false end
  local ok, destroyed = pcall(function()
    if w.isDestroyed then return w:isDestroyed() end
    return false
  end)
  if ok and destroyed == true then return false end
  return true
end

local function debugPotion(msg)
  if not (CFG and CFG.debug) then return end
  local t = nowMs()
  local thr = tonumber(CFG.potionLogThrottleMs) or 2500
  G._nextPotionLog = G._nextPotionLog or 0
  if t < G._nextPotionLog then return end
  G._nextPotionLog = t + thr
  print(msg)
end

-- ========== UI HELPERS ==========

local function getHudParent()
  -- Prefer the map panel, so labels are always visible above the game view.
  local parent = nil

  if modules and modules.game_interface then
    if modules.game_interface.getMapPanel then
      local ok, p = pcall(modules.game_interface.getMapPanel)
      if ok and widgetAlive(p) then parent = p end
    end
    if not parent and modules.game_interface.getRootPanel then
      local ok, p = pcall(modules.game_interface.getRootPanel)
      if ok and widgetAlive(p) then parent = p end
    end
  end

  if not parent and g_ui and g_ui.getRootWidget then
    local root = g_ui.getRootWidget()
    if widgetAlive(root) then
      local ok, p = pcall(function() return root:recursiveGetChildById("gameMapPanel") end)
      if ok and widgetAlive(p) then parent = p end
      if not parent then
        ok, p = pcall(function() return root:recursiveGetChildById("mapPanel") end)
        if ok and widgetAlive(p) then parent = p end
      end
      if not parent then parent = root end
    end
  end

  return parent
end

local function ensureStatusLabel()
  if widgetAlive(G._statusLabel) then return G._statusLabel end
  if not g_ui or not g_ui.getRootWidget or not g_ui.createWidget then return nil end

  local root = getHudParent()
  if not widgetAlive(root) then return nil end

  -- Reuse existing widget by id to avoid duplicates/leaks across reloads
  if type(root.recursiveGetChildById) == "function" then
    local ok, existing = pcall(root.recursiveGetChildById, root, "GiftOfLifeStatus")
    if ok and widgetAlive(existing) then
      G._statusLabel = existing
      return existing
    end
  elseif type(root.getChildById) == "function" then
    local ok, existing = pcall(root.getChildById, root, "GiftOfLifeStatus")
    if ok and widgetAlive(existing) then
      G._statusLabel = existing
      return existing
    end
  end


  local label
  local ok, w = pcall(function() return g_ui.createWidget("UILabel", root) end)
  if ok and w then label = w end
  if not label then
    ok, w = pcall(function() return g_ui.createWidget("Label", root) end)
    if ok and w then label = w end
  end
  if not label then return nil end

  pcall(function() label:setId("GiftOfLifeStatus") end)
  pcall(function() label:setText("GiftOfLife: ...") end)
  pcall(function() label:setPadding(4) end)
  pcall(function() label:setPhantom(true) end)
  pcall(function() label:setPosition({ x = 10, y = 35 }) end)
    pcall(function() label:setBackgroundColor("#00000066") end)
  pcall(function() label:setPosition({ x = 20, y = 35 }) end)

  G._statusLabel = label
  pcall(function() if _G.GoLLeakGuard and type(_G.GoLLeakGuard.track) == "function" then _G.GoLLeakGuard.track(label) end end)
  return label
end

local function setStatusText()
  local label = ensureStatusLabel()

  local running = (G.enabled == true)
  local healOn = (G.flags and G.flags.heal) and true or false
  local manaOn = (G.flags and G.flags.mana) and true or false
  local lootOn = (G.flags and G.flags.loot) and true or false

  local txt = string.format("GoL: %s  (Heal:%s Mana:%s Loot:%s)",
    running and "RUN" or "STOP",
    healOn and "ON" or "OFF",
    manaOn and "ON" or "OFF",
    lootOn and "ON" or "OFF")

  local col = running and "#00ff3a" or "#ff2b2b"

  pcall(function() if label then label:setText(txt) end end)
  pcall(function() if label then label:setColor(col) end end)

  local win = ensureWindow()
  if win then
    local wlabel = getUiChild(win, "winStatusLabel")
    if wlabel then
      pcall(function() wlabel:setText(txt) end)
      pcall(function() wlabel:setColor(col) end)
    end
  end
end

local function ensureHudLabel()
  if widgetAlive(G._hud) then return G._hud end
  if not g_ui or not g_ui.getRootWidget or not g_ui.createWidget then return nil end

  local root = getHudParent()
  if not widgetAlive(root) then return nil end

  -- Reuse existing widget by id to avoid duplicates/leaks across reloads
  if type(root.recursiveGetChildById) == "function" then
    local ok, existing = pcall(root.recursiveGetChildById, root, "GiftOfLifeHud")
    if ok and widgetAlive(existing) then
      G._hud = existing
      return existing
    end
  elseif type(root.getChildById) == "function" then
    local ok, existing = pcall(root.getChildById, root, "GiftOfLifeHud")
    if ok and widgetAlive(existing) then
      G._hud = existing
      return existing
    end
  end


  local hud
  local ok, w = pcall(function() return g_ui.createWidget("UILabel", root) end)
  if ok and w then hud = w end
  if not hud then
    ok, w = pcall(function() return g_ui.createWidget("Label", root) end)
    if ok and w then hud = w end
  end
  if not hud then return nil end

  pcall(function() hud:setId("GiftOfLifeHud") end)
  pcall(function() hud:setText("") end)
  pcall(function() hud:setFont("verdana-11px-rounded") end)
  pcall(function() hud:setColor("#ffffff") end)
  pcall(function() hud:setPhantom(true) end)
  pcall(function() hud:setPosition({ x = 10, y = 10 }) end)

  G._hud = hud
  pcall(function() if _G.GoLLeakGuard and type(_G.GoLLeakGuard.track) == "function" then _G.GoLLeakGuard.track(hud) end end)
  return hud
end

-- ========== GAME READERS ==========
local function getManaAbs(lp)
  if not lp then return nil, nil end
  local ok1, cur = callAny(lp, "getMana")
  local ok2, mx  = callAny(lp, "getMaxMana")
  if ok1 and ok2 and type(cur) == "number" and type(mx) == "number" and mx > 0 then
    return cur, mx
  end
  return nil, nil
end

local function getPercent(lp, kind)
  if not lp then return nil end

  if kind == "hp" then
    local ok, v = callAny(lp, "getHealthPercent")
    if ok and type(v) == "number" then return normalizePct(v) end

    local ok1, cur = callAny(lp, "getHealth")
    local ok2, mx  = callAny(lp, "getMaxHealth")
    if ok1 and ok2 and type(cur) == "number" and type(mx) == "number" and mx > 0 then
      return normalizePct((cur / mx) * 100)
    end
  end

  if kind == "mp" then
    local calcPct = nil
    local ok1, cur = callAny(lp, "getMana")
    local ok2, mx  = callAny(lp, "getMaxMana")
    if ok1 and ok2 and type(cur) == "number" and type(mx) == "number" and mx > 0 then
      calcPct = normalizePct((cur / mx) * 100)
    end

    local apiPct = nil
    local ok, v = callAny(lp, "getManaPercent")
    if ok and type(v) == "number" then
      apiPct = normalizePct(v)
    end

    if type(calcPct) == "number" then return calcPct end
    if type(apiPct) == "number" then return apiPct end

    return 100
  end

  return nil
end

local function castSpell(words)
  if not words or words == "" then return end
  if not g_game then return end
  callAny(g_game, "talk", words)
  pushUiLog("Spell: " .. tostring(words))
end

-- ========== POTION LOGIC ==========
local function findPotionItem(itemId)
  local ok, item = callAny(g_game, "findPlayerItem", itemId)
  if ok and item then return item end
  return nil
end

local function getItemCount(item)
  if not item then return 0 end
  -- OTC forks vary: getCount(), getAmount(), or a .count field
  if item.getCount then
    local ok, c = pcall(item.getCount, item)
    if ok and type(c) == "number" then return c end
  end
  if item.getAmount then
    local ok, c = pcall(item.getAmount, item)
    if ok and type(c) == "number" then return c end
  end
  if type(item.count) == "number" then return item.count end
  return 1
end

local function getItemId(item)
  if not item then return nil end
  if item.getId then
    local ok, id = pcall(item.getId, item)
    if ok and type(id) == "number" then return id end
  end
  if type(item.id) == "number" then return item.id end
  return nil
end

-- ========== LOOT ==========
local function listToSet(list)
  local set = {}
  if type(list) == "table" then
    for _, v in ipairs(list) do
      if type(v) == "number" then
        set[v] = true
      end
    end
  end
  return set
end

local function getContainersSorted()
  if not g_game or type(g_game.getContainers) ~= "function" then return {} end
  local containers = g_game.getContainers()
  if type(containers) ~= "table" then return {} end

  local list = {}
  for k, c in pairs(containers) do
    if c then
      table.insert(list, { key = k, c = c })
    end
  end

  table.sort(list, function(a, b)
    local na, nb = tonumber(a.key), tonumber(b.key)
    if na and nb then return na < nb end
    return tostring(a.key) < tostring(b.key)
  end)

  return list
end

local function getContainerByNth(nth)
  nth = tonumber(nth)
  if not nth or nth < 1 then return nil end
  local list = getContainersSorted()
  return (list[nth] and list[nth].c) or nil
end

local function safeGetNameLower(c)
  local ok, name = callAny(c, "getName")
  if ok and type(name) == "string" then return name:lower() end
  return ""
end

local function nameContainsAny(name, parts)
  if type(name) ~= "string" then return false end
  if type(parts) ~= "table" then return false end
  for _, p in ipairs(parts) do
    if type(p) == "string" and p ~= "" and name:find(p, 1, true) then
      return true
    end
  end
  return false
end

-- Container item access differs between OTC forks.
-- These helpers provide safe fallbacks for getItemsCount / getItems / slot iteration.
local function getContainerItemsCountAny(c)
  if not c then return 0 end

  local ok, cnt = callAny(c, "getItemsCount")
  if ok and type(cnt) == "number" then return cnt end

  local okItems, items = callAny(c, "getItems")
  if okItems and type(items) == "table" then return #items end

  local okCap, cap = callAny(c, "getCapacity")
  if not okCap or type(cap) ~= "number" or cap <= 0 then
    okCap, cap = callAny(c, "getSize")
  end
  if type(cap) ~= "number" or cap <= 0 then return 0 end

  local count = 0
  for slot = 0, cap - 1 do
    local okIt, it = callAny(c, "getItem", slot)
    if okIt and it then count = count + 1 end
  end
  return count
end

local function getContainerItemsAny(c)
  if not c then return {} end

  local okItems, items = callAny(c, "getItems")
  if okItems and type(items) == "table" then return items end

  local okCap, cap = callAny(c, "getCapacity")
  if not okCap or type(cap) ~= "number" or cap <= 0 then
    okCap, cap = callAny(c, "getSize")
  end
  if type(cap) ~= "number" or cap <= 0 then return {} end

  local out = {}
  for slot = 0, cap - 1 do
    local okIt, it = callAny(c, "getItem", slot)
    if okIt and it then out[#out + 1] = it end
  end
  return out
end


local function findFirstEmptySlot(dest)
  local okCap, cap = callAny(dest, "getCapacity")
  if not okCap or type(cap) ~= "number" or cap <= 0 then
    okCap, cap = callAny(dest, "getSize")
  end
  if type(cap) ~= "number" or cap <= 0 then return nil end

  for slot = 0, cap - 1 do
    local ok, it = callAny(dest, "getItem", slot)
    if not ok or it == nil then
      return slot
    end
  end
  return nil
end

local function tryOpenNextBackpack(dest)
  if not (CFG and CFG.loot and CFG.loot.openNextOnFull) then return false end
  if not g_game then return false end

  -- Throttle to avoid opening loops on some forks
  G._lastOpenNextAt = G._lastOpenNextAt or 0
  local now = tonumber(G._nowMs) or 0
  local cd = tonumber(CFG.loot.openNextCooldownMs) or 800
  if now > 0 and (now - G._lastOpenNextAt) < cd then
    return false
  end

  local items = getContainerItemsAny(dest)
  if type(items) ~= "table" or #items == 0 then return false end

  for _, it in ipairs(items) do
    if it and type(it.isContainer) == "function" then
      local okc, isC = pcall(it.isContainer, it)
      if okc and isC then
        -- Prefer opening inside the destination container if supported.
        local ok = false
        if type(g_game.open) == "function" then
          ok = pcall(g_game.open, it, dest)
          if not ok then ok = pcall(g_game.open, it) end
        elseif type(g_game.openContainer) == "function" then
          ok = pcall(g_game.openContainer, it, dest)
          if not ok then ok = pcall(g_game.openContainer, it) end
        end
        if ok then
          G._lastOpenNextAt = now
          return true
        end
      end
    end
  end
  return false
end



local function isStackableAny(it)
  if not it then return false end
  if type(it.isStackable) == "function" then
    local ok, v = pcall(it.isStackable, it)
    if ok and type(v) == "boolean" then return v end
  end
  return false
end

local function isGoldId(id)
  return id == 3031 or id == 3035 or id == 3043
end

local function getStackMaxById(id)
  -- Server-specific: gold stacks up to 200 on this server.
  if isGoldId(id) then
    return tonumber(CFG.loot.goldStackMax) or 200
  end
  return tonumber(CFG.loot.stackMax) or 100
end

local getItemId -- forward declaration (fix scope)

local function findStackTargetSlot(dest, itemId)
  if not dest or type(itemId) ~= "number" then return nil end
  local items = getContainerItemsAny(dest)
  if type(items) ~= "table" or #items == 0 then return nil end
  for idx, it in ipairs(items) do
    if getItemId(it) == itemId then
      local cnt = getItemCount(it)
      if (isStackableAny(it) or isGoldId(itemId)) and type(cnt) == "number" and cnt < getStackMaxById(itemId) then
        return idx - 1 -- slot index is 0-based
      end
    end
  end
  return nil
end

local function moveToContainer(item, dest, preferSlot)
  if not item or not dest then return false, "missing" end
  if not g_game or type(g_game.move) ~= "function" then return false, "no_move" end

  local slot = (type(preferSlot) == "number") and preferSlot or nil
  if slot == nil then
    slot = findFirstEmptySlot(dest)
    if slot == nil then
      if tryOpenNextBackpack(dest) then
        return false, "opened_next"
      end
      return false, "full"
    end
  end

  local okPos, pos = callAny(dest, "getSlotPosition", slot)
  if not okPos or not pos then return false, "no_pos" end

  local count = getItemCount(item)
  local ok, err = pcall(g_game.move, item, pos, count)
  if not ok then return false, err end
  return true
end


local function maybeChangeCoinsInContainer(dest, LDBG, t)
  if not dest then return false end
  if tostring(CFG.loot.coinChangeEnabled) == "false" then return false end
  if not g_game then return false end

  local threshold = tonumber(CFG.loot.coinChangeThreshold) or (tonumber(CFG.loot.goldStackMax) or 200)
  local cd = tonumber(CFG.loot.coinChangeCooldownMs) or 800
  local maxUses = tonumber(CFG.loot.coinChangeMaxUsesPerTick) or 1

  G._lastCoinUseAt = tonumber(G._lastCoinUseAt) or 0
  if t < (G._lastCoinUseAt + cd) then return false end

  local items = getContainerItemsAny(dest)
  if type(items) ~= "table" or #items == 0 then return false end

  local used = 0
  for _, it in ipairs(items) do
    local id = getItemId(it)
    if isGoldId(id) then
      local cnt = getItemCount(it)
      if type(cnt) == "number" and cnt >= threshold then
        local ok = callAny(g_game, "use", it)
        if ok then
          used = used + 1
          G._lastCoinUseAt = t
          if LDBG then LDBG.last = string.format("COIN_USE id=%s x%s", tostring(id), tostring(cnt)) end
        end
        if used >= maxUses then break end
      end
    end
  end

  return used > 0
end

local function compressStacksInContainer(dest, maxMoves)
  if not dest then return 0 end
  if not g_game or type(g_game.move) ~= "function" then return 0 end
  maxMoves = tonumber(maxMoves) or 1
  if maxMoves <= 0 then return 0 end

  -- We NEED stable slot indexes; prefer getCapacity/getItem APIs.
  local okCap, cap = callAny(dest, "getCapacity")
  if not okCap or type(cap) ~= "number" then
    okCap, cap = callAny(dest, "getSize")
  end
  cap = tonumber(cap) or 0
  if cap <= 0 then return 0 end

  if type(dest.getItem) ~= "function" and type(dest["getItem"]) ~= "function" then
    -- Some forks expose only getItems() (no stable slots) -> skip (safe).
    return 0
  end

  if type(dest.getSlotPosition) ~= "function" and type(dest["getSlotPosition"]) ~= "function" then
    return 0
  end

  -- Collect partial stacks by id with their real slot index.
  local byId = {}
  for slot = 0, cap - 1 do
    local okIt, it = callAny(dest, "getItem", slot)
    if okIt and it then
      local id = getItemId(it)
      if id and (isGoldId(id) or isStackableAny(it)) then
        local cnt = getItemCount(it)
        local maxStack = getStackMaxById(id)
        if type(cnt) == "number" and cnt > 0 and cnt < maxStack then
          byId[id] = byId[id] or {}
          table.insert(byId[id], { slot = slot, item = it, count = cnt, maxStack = maxStack })
        end
      end
    end
  end

  local moved = 0

  for id, list in pairs(byId) do
    if moved >= maxMoves then break end
    -- Prefer filling stacks that are already most-full.
    table.sort(list, function(a, b)
      if a.count == b.count then return a.slot < b.slot end
      return a.count > b.count
    end)

    local i = 1
    while i <= #list and moved < maxMoves do
      local dst = list[i]
      local maxStack = dst.maxStack or getStackMaxById(id)
      if dst.count >= maxStack then
        i = i + 1
      else
        local j = #list
        while j > i and moved < maxMoves and dst.count < maxStack do
          local src = list[j]
          if src.slot == dst.slot then
            j = j - 1
          else
            local need = maxStack - dst.count
            local take = math.min(src.count or 0, need)
            if take <= 0 then
              j = j - 1
            else
              local okPos, pos = callAny(dest, "getSlotPosition", dst.slot)
              if not okPos or not pos then
                break
              end
              local okMove = pcall(g_game.move, src.item, pos, take)
              if okMove then
                moved = moved + 1
                dst.count = (dst.count or 0) + take
                src.count = (src.count or 0) - take
                if src.count <= 0 then
                  table.remove(list, j)
                end
              else
                break
              end
              j = j - 1
            end
          end
        end
        i = i + 1
      end
    end
  end

  return moved
end

getItemId = function(item)
  local ok, id = callAny(item, "getId")
  if ok and type(id) == "number" then return id end
  return nil
end

local function shouldLootId(id, mode, set, ignore)
  if not id then return false end
  if ignore[id] then return false end
  if mode == "all" then return true end
  return set[id] == true
end

local function doLootTick(t)
  if not (G.flags and G.flags.loot) then return end
  if not (CFG and CFG.loot) then return end

  G._nowMs = t

  -- Loot debug/telemetry (v10f)
  G._lootDbg = G._lootDbg or {}
  local LDBG = G._lootDbg
  LDBG.enabled = true
  LDBG.mode = tostring(CFG.loot.mode or "list")
  LDBG.srcItems = 0
  LDBG.source = "none"
  LDBG.skip = ""
  LDBG.last = ""
  LDBG.err = ""
  local moveBlocked = false
  local blockReason = ""
  didMove = false
  -- didMaintenance already tracked above
  G._lastLootAt = G._lastLootAt or 0
  local cd = tonumber(CFG.loot.moveCooldownMs) or 120
  if t < (G._lastLootAt + cd) then
    moveBlocked = true
    blockReason = "COOLDOWN"
    LDBG.skip = "COOLDOWN"
  end


-- Low capacity safety (v10i)
local minCap = tonumber(CFG.loot.minCap) or 0
local cap = nil
if minCap > 0 and g_game then
  local okP, player = callAny(g_game, "getLocalPlayer")
  if okP and player then
    local okF, fc = callAny(player, "getFreeCapacity")
    if okF and type(fc) == "number" then cap = fc end
    if cap == nil then
      local okF2, fc2 = callAny(player, "getFreeCap")
      if okF2 and type(fc2) == "number" then cap = fc2 end
    end
    if cap == nil then
      local okC, c = callAny(player, "getCapacity")
      if okC and type(c) == "number" then cap = c end
    end
  end
end
LDBG.cap = cap
if minCap > 0 and type(cap) == "number" and cap < minCap then
  LDBG.skip = "LOW_CAP"
  if tostring(CFG.loot.lowCapBehavior or "skip") == "pauseLoot" then
    G.flags.loot = false
    LDBG.last = "AUTO_OFF (LOW_CAP)"
  end
  moveBlocked = true
  blockReason = "LOW_CAP"
end

  -- Hardening: after opening next backpack, wait a moment for the container to appear before moving again.
  local waitUntil = tonumber(G._lootWaitDestUntil) or 0
  if waitUntil > 0 and t < waitUntil then
    moveBlocked = true
    blockReason = "WAIT_DEST"
    LDBG.skip = "WAIT_DEST"
  end
  if waitUntil > 0 and t >= waitUntil then
    G._lootWaitDestUntil = 0
  end

  local mainBp  = getContainerByNth(CFG.loot.mainBpNth or 1)
  local lootBp  = getContainerByNth(CFG.loot.lootBpNth or 2)
  local stackBp = getContainerByNth(CFG.loot.stackBpNth or 3)

  if not mainBp or not lootBp then
    moveBlocked = true
    blockReason = "NO_DEST"
    LDBG.skip = "NO_DEST"
  end

  if not moveBlocked then
  repeat
  local source = nil
  local sourceKey = nil

  if CFG.loot.sourcePolicy == "nth" then
    source = getContainerByNth(CFG.loot.sourceNth or 4)
  else
    local list = getContainersSorted()
    local candidates = {}

    for i = 1, #list do
      local key = list[i].key
      local c = list[i].c
      if c and c ~= mainBp and c ~= lootBp and c ~= stackBp then
        local name = safeGetNameLower(c)
        if not nameContainsAny(name, CFG.loot.skipNameContains) then
          local cnt = getContainerItemsCountAny(c)
          if type(cnt) == "number" and cnt > 0 then
            table.insert(candidates, { key = key, c = c, cnt = cnt, name = name })
          end
        end
      end
    end

    -- Hardening: pin the source container for a short time so multiple corpses don't cause flapping.
    local pinMs = tonumber(CFG.loot.sourcePinMs) or 6000
    local pinnedKey = G._lootPinnedKey
    local pinnedUntil = tonumber(G._lootPinnedUntil) or 0
    if pinnedKey ~= nil then
      -- v10l: keep pinned source until it is emptied (with a failsafe).
      local pinnedC = nil
      for i = 1, #list do
        if tostring(list[i].key) == tostring(pinnedKey) then
          pinnedC = list[i].c
          break
        end
      end

      if pinnedC then
        local cntPinned = getContainerItemsCountAny(pinnedC)
        if type(cntPinned) == "number" and cntPinned > 0 then
          source = pinnedC
          sourceKey = pinnedKey
          -- refresh failsafe
          G._lootPinnedUntil = t + pinMs
        else
          -- empty -> release pin
          G._lootPinnedKey = nil
          G._lootPinnedUntil = 0
          pinnedKey = nil
        end
      else
        -- if pinned container is missing for too long, release it
        if t >= pinnedUntil then
          G._lootPinnedKey = nil
          G._lootPinnedUntil = 0
          pinnedKey = nil
        end
      end
    end

    if not source and #candidates > 0 then
      local cand = candidates[#candidates] -- newest/highest key
      source = cand.c
      sourceKey = cand.key
      G._lootPinnedKey = cand.key
      G._lootPinnedUntil = t + pinMs
    end
  end

  if not source then
    LDBG.skip = "NO_SOURCE"
    blockReason = blockReason ~= "" and blockReason or "NO_SOURCE"
    break
  end


  local mode = tostring(CFG.loot.mode or "list")
  local lootSet   = listToSet(CFG.loot.itemIds)
  local ignoreSet = listToSet(CFG.loot.ignoreIds)
  local goldSet   = listToSet(CFG.loot.goldIds)
  local stackSet  = listToSet(CFG.loot.stackIds)

  local items = getContainerItemsAny(source)
  if type(items) ~= "table" or #items == 0 then
    -- v10l: if our pinned source became empty, release pin immediately.
    if sourceKey ~= nil and tostring(G._lootPinnedKey) == tostring(sourceKey) then
      G._lootPinnedKey = nil
      G._lootPinnedUntil = 0
    end
    LDBG.skip = "EMPTY_SOURCE"
    blockReason = blockReason ~= "" and blockReason or "EMPTY_SOURCE"
    break
  end
  LDBG.srcItems = #items
    local okSid, sid = callAny(source, "getId")
  local okSname, sname = callAny(source, "getName")
  LDBG.source = string.format("id=%s name=%s", tostring((okSid and sid) or "?"), tostring((okSname and sname) or "?"))

  local moves = 0
  local maxMoves = tonumber(CFG.loot.maxMovesPerTick) or 1
  didMove = false
  didMaintenance = false
  for _, it in ipairs(items) do
    local id = getItemId(it)
    if shouldLootId(id, mode, lootSet, ignoreSet) then
      local dest = lootBp
      if goldSet[id] then
        dest = mainBp
      elseif stackBp and stackSet[id] then
        dest = stackBp
      end

      local preferSlot = nil


      if tostring(CFG.loot.stackIntoExisting) ~= "false" then


        if goldSet[id] or stackSet[id] then


          preferSlot = findStackTargetSlot(dest, id)


        end


      end



      local ok, why = moveToContainer(it, dest, preferSlot)
      G._lastLootAt = t
      local destTag = (dest == lootBp) and "LOOT" or ((dest == mainBp) and "MAIN" or "STACK")
      LDBG.last = string.format("MOVE id=%s x%s -> %s : %s", tostring(id), tostring(getItemCount(it) or "?"), destTag, ok and "OK" or ("FAIL(" .. tostring(why) .. ")"))
      if not ok then
        LDBG.err = tostring(why)
        if tostring(why) == "opened_next" then
          local waitMs = tonumber(CFG.loot.openWaitMs) or 650
          G._lootWaitDestUntil = t + waitMs
          LDBG.skip = "WAIT_DEST"
          blockReason = "WAIT_DEST"
          break
        end
      end
      if ok then
        didMove = true
        moves = moves + 1
        if moves >= maxMoves then break end
      else
        break
      end
    end
  end
  until true
  end

  -- QoL: stack sorter inside destination backpacks (saves slots by merging partial stacks)
  if tostring(CFG.loot.sorterEnabled) ~= "false" then
    G._lastSortAt = tonumber(G._lastSortAt) or 0
    local sortCd = tonumber(CFG.loot.sorterCooldownMs) or 600
    if t >= (G._lastSortAt + sortCd) then
      local sortMoves = tonumber(CFG.loot.sorterMaxMovesPerTick) or 1
      local done = 0
      done = done + compressStacksInContainer(mainBp, sortMoves - done)
      if stackBp and done < sortMoves then done = done + compressStacksInContainer(stackBp, sortMoves - done) end
      if done < sortMoves then done = done + compressStacksInContainer(lootBp, sortMoves - done) end
      if done > 0 then
        didMaintenance = true
        G._lastSortAt = t
        LDBG.last = string.format("SORT moves=%s", tostring(done))
      end
    end
  end

  -- QoL: coin change (server uses 'use' on coin stack; gold stacks up to 200)
  if tostring(CFG.loot.coinChangeEnabled) ~= "false" then
    if maybeChangeCoinsInContainer(mainBp, LDBG, t) then
      didMaintenance = true
    end
  end

  if moveBlocked and (LDBG.skip == nil or LDBG.skip == "") and blockReason ~= "" then
    LDBG.skip = blockReason
  end

  if not didMove and not didMaintenance and (LDBG.skip == nil or LDBG.skip == "") then
    LDBG.skip = "NO_MATCH"
  end

end

local function countPotionInContainers(itemId)
  if not g_game then return 0 end

  local total = 0
  local ok, containers = callAny(g_game, "getContainers")
  if ok and type(containers) == "table" then
    for _, c in pairs(containers) do
      local okItems, items = callAny(c, "getItems")
      if okItems and type(items) == "table" then
        for _, it in pairs(items) do
          local okId, id = callAny(it, "getId")
          if okId and id == itemId then
            total = total + getItemCount(it)
          end
        end
      end
    end
    return total
  end

  local it = findPotionItem(itemId)
  return getItemCount(it)
end

local function getTotalPotionCount()
  local total = 0
  for _, id in ipairs(CFG.manaPotionIds or {}) do
    total = total + countPotionInContainers(id)
  end
  return total
end

local function tryUsePotion(itemId, lp)
  if not g_game then return false end
  local item = findPotionItem(itemId)

  if lp then
    if item then
      local ok = callAny(g_game, "useInventoryItemWith", item, lp)
      if ok then
        debugPotion(string.format("[GiftOfLife] potion useInventoryItemWith(item, lp) id=%d", itemId))
        pushUiLog("Potion: " .. tostring(itemId))
        return true
      end
    end

    local ok = callAny(g_game, "useInventoryItemWith", itemId, lp)
    if ok then
      debugPotion(string.format("[GiftOfLife] potion useInventoryItemWith(id, lp) id=%d", itemId))
      pushUiLog("Potion: " .. tostring(itemId))
      return true
    end
  end

  if item and lp then
    local ok = callAny(g_game, "useWith", item, lp)
    if ok then
      debugPotion(string.format("[GiftOfLife] potion useWith(item, lp) id=%d", itemId))
      pushUiLog("Potion: " .. tostring(itemId))
      return true
    end
  end

  local ok = callAny(g_game, "useInventoryItem", itemId)
  if ok then
    debugPotion(string.format("[GiftOfLife] potion useInventoryItem id=%d", itemId))
    pushUiLog("Potion: " .. tostring(itemId))
    return true
  end

  if CFG.allowDirectUse == true and item then
    local ok2 = callAny(g_game, "use", item)
    if ok2 then
      debugPotion(string.format("[GiftOfLife] potion use(item) id=%d", itemId))
      pushUiLog("Potion: " .. tostring(itemId))
      return true
    end
  end

  return false
end

local function clampNumber(v, lo, hi)
  if type(v) ~= "number" then return lo end
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function randBetween(a, b)
  if type(a) ~= "number" and type(b) ~= "number" then return nil end
  if type(a) ~= "number" then a = b end
  if type(b) ~= "number" then b = a end
  if a > b then a, b = b, a end
  if math.random then return math.random(a, b) end
  return math.floor((a + b) / 2)
end

local function buildManaProfilesAbs()
  local list = {}

  local sMin = CFG.manaStartManaMin
  local sMax = CFG.manaStartManaMax
  local tMin = CFG.manaStopManaMin
  local tMax = CFG.manaStopManaMax

  if type(CFG.manaStartMana) == "number" and type(sMin) ~= "number" and type(sMax) ~= "number" then
    sMin, sMax = CFG.manaStartMana, CFG.manaStartMana
  end
  if type(CFG.manaStopMana) == "number" and type(tMin) ~= "number" and type(tMax) ~= "number" then
    tMin, tMax = CFG.manaStopMana, CFG.manaStopMana
  end

  if type(sMin) == "number" or type(sMax) == "number" or type(tMin) == "number" or type(tMax) == "number" then
    table.insert(list, { startMin = sMin, startMax = sMax, stopMin = tMin, stopMax = tMax })
  end

  if type(CFG.manaRanges) == "table" then
    for _, r in ipairs(CFG.manaRanges) do
      if type(r) == "table" and (r.startManaMin or r.startManaMax or r.stopManaMin or r.stopManaMax or r.startMana or r.stopMana) then
        local a1, a2 = r.startManaMin, r.startManaMax
        local b1, b2 = r.stopManaMin, r.stopManaMax
        if type(r.startMana) == "number" and type(a1) ~= "number" and type(a2) ~= "number" then a1, a2 = r.startMana, r.startMana end
        if type(r.stopMana) == "number" and type(b1) ~= "number" and type(b2) ~= "number" then b1, b2 = r.stopMana, r.stopMana end
        table.insert(list, { startMin = a1, startMax = a2, stopMin = b1, stopMax = b2 })
      end
    end
  end

  return list
end

local function buildManaProfilesPct()
  local list = {}

  local sMin = CFG.manaStartPctMin
  local sMax = CFG.manaStartPctMax
  local tMin = CFG.manaStopPctMin
  local tMax = CFG.manaStopPctMax

  if type(CFG.manaStartPct) == "number" and type(sMin) ~= "number" and type(sMax) ~= "number" then
    sMin, sMax = CFG.manaStartPct, CFG.manaStartPct
  end
  if type(CFG.manaStopPct) == "number" and type(tMin) ~= "number" and type(tMax) ~= "number" then
    tMin, tMax = CFG.manaStopPct, CFG.manaStopPct
  end

  table.insert(list, { startMin = sMin, startMax = sMax, stopMin = tMin, stopMax = tMax })

  if type(CFG.manaRanges) == "table" then
    for _, r in ipairs(CFG.manaRanges) do
      if type(r) == "table" and (r.startPctMin or r.startPctMax or r.stopPctMin or r.stopPctMax or r.startPct or r.stopPct) then
        local a1, a2 = r.startPctMin, r.startPctMax
        local b1, b2 = r.stopPctMin, r.stopPctMax
        if type(r.startPct) == "number" and type(a1) ~= "number" and type(a2) ~= "number" then a1, a2 = r.startPct, r.startPct end
        if type(r.stopPct) == "number" and type(b1) ~= "number" and type(b2) ~= "number" then b1, b2 = r.stopPct, r.stopPct end
        table.insert(list, { startMin = a1, startMax = a2, stopMin = b1, stopMax = b2 })
      end
    end
  end

  return list
end

local function ensureManaTargets(useAbs)
  if G._manaUseAbs ~= useAbs then
    G._manaUseAbs = useAbs
    G._manaStartTarget = nil
    G._manaStopTarget = nil
  end

  if G._manaStartTarget ~= nil and G._manaStopTarget ~= nil then return end

  local profiles = useAbs and buildManaProfilesAbs() or buildManaProfilesPct()
  if type(profiles) ~= "table" or #profiles == 0 then
    if useAbs then
      G._manaStartTarget = (type(CFG.manaStartMana) == "number") and CFG.manaStartMana or -math.huge
      G._manaStopTarget  = (type(CFG.manaStopMana) == "number") and CFG.manaStopMana  or  math.huge
    else
      G._manaStartTarget = (type(CFG.manaStartPct) == "number") and CFG.manaStartPct or 0
      G._manaStopTarget  = (type(CFG.manaStopPct) == "number") and CFG.manaStopPct  or 100
    end
    return
  end

  local pick = profiles[math.random(1, #profiles)]
  local startV = randBetween(pick.startMin, pick.startMax)
  local stopV  = randBetween(pick.stopMin, pick.stopMax)

  if useAbs then
    startV = tonumber(startV) or (tonumber(CFG.manaStartMana) or 0)
    stopV  = tonumber(stopV)  or (tonumber(CFG.manaStopMana)  or 0)
  else
    startV = clampNumber(tonumber(startV) or tonumber(CFG.manaStartPct) or 0, 0, 100)
    stopV  = clampNumber(tonumber(stopV)  or tonumber(CFG.manaStopPct)  or 100, 0, 100)
  end

  if startV > stopV then startV, stopV = stopV, startV end

  G._manaStartTarget = startV
  G._manaStopTarget  = stopV
end

local function drinkPotion(lp, t)
  local noUntil = G._noPotsUntilMs or 0
  if type(t) == "number" and t < noUntil then return false end

  local total = getTotalPotionCount()
  if total <= 0 then
    local now = type(t) == "number" and t or nowMs()
    local backoff = tonumber(CFG.noPotRetryMs) or 5000
    G._noPotsUntilMs = now + backoff

    if CFG.debug then
      local nextLog = G._noPotLogNextMs or 0
      if now >= nextLog then
        G._noPotLogNextMs = now + (tonumber(CFG.noPotLogThrottleMs) or 8000)
        print(string.format("[GiftOfLife] no mana potions left (retry in %dms)", backoff))
      end
    end
    return false
  end

  for _, id in ipairs(CFG.manaPotionIds or {}) do
    if tryUsePotion(id, lp) then return true end
  end

  debugPotion("[GiftOfLife] potion failed (likely wrong item id for your server)")
  return false
end

-- Optional console helper: shows which IDs you actually have
G.printPotionCandidates = function()
  if not g_game or not g_game.isOnline or not g_game.isOnline() then
    print("[GiftOfLife] offline")
    return
  end
  for _, id in ipairs(CFG.manaPotionIds or {}) do
    local item = findPotionItem(id)
    print(string.format("[GiftOfLife] id=%d present=%s", id, item and "YES" or "no"))
  end
end

-- ========== LOOP ==========
local function stopLoop()
  G.enabled = false
  if G._evt and removeEvent then pcall(function() removeEvent(G._evt) end) end
  G._evt = nil
  setStatusText()
  -- 'win' is local in other scopes; resolve safely here.
  local w = nil
  if widgetAlive(G._window) then w = G._window end
  if not w and type(ensureWindow) == "function" then w = ensureWindow() end
  if type(updateQuickButtons) == "function" then
    updateQuickButtons(w)
  end
end

local function scheduleNext()
  if not G.enabled then return end

  local fn = function()
    if G.enabled and G._tick and G._loadToken == LOAD_TOKEN then G._tick() end
  end

  if scheduleEvent then
    G._evt = safeTrackEvent(scheduleEvent(fn, CFG.tickMs), "GoL.event")
    return
  end
  if g_dispatcher and g_dispatcher.scheduleEvent then
    G._evt = g_dispatcher.scheduleEvent(fn, CFG.tickMs)
    return
  end

  print("[GiftOfLife] No scheduler found. Disabling.")
  stopLoop()
end

local function startLoop()
  if G.enabled then return end
  G.enabled = true
  G._lastSpellMs = 0
  G._lastPotionMs = 0
  G._drinking = false
  setStatusText()
  if G._tick then G._tick() end
end

local function shouldRun()
  local healOn = (G.flags and G.flags.heal) and true or false
  local manaOn = (G.flags and G.flags.mana) and true or false
  local lootOn = (G.flags and G.flags.loot) and true or false
  return healOn or manaOn or lootOn
end


-- UI helpers (console)
G.uiShow = function()
  G._uiSuppressed = false
  local win = ensureWindow()
  if win then
    pcall(function() win:show() end)
    pcall(function() win:raise() end)
    pcall(function() win:focus() end)
  end
end

G.uiHide = function()
  G._uiSuppressed = true
  if G._window then pcall(function() G._window:hide() end) end
end

G.uiToggle = function()
  if G._uiSuppressed == true then
    return G.uiShow()
  end
  local win = ensureWindow()
  if not win then return end
  local ok, vis = pcall(function() return win:isVisible() end)
  if ok and vis then G.uiHide() else G.uiShow() end
end

G.start = function() startLoop() end
G.stop  = function() stopLoop() end
G.toggle = function()
  if G.enabled then stopLoop() else startLoop() end
end
G.isRunning = function() return G.enabled == true end

-- Initialize flags once (do not overwrite user toggles on reload)
G.flags = G.flags or {
  heal = (CFG.healEnabled ~= false),
  mana = (CFG.manaEnabled ~= false),
  loot = (CFG.lootEnabled == true),
}

G._tick = function()
  local t = nowMs()

  if not g_game or not g_game.isOnline or not g_game.isOnline() then
    scheduleNext(); return
  end
  if g_game.isDead and g_game.isDead() then
    scheduleNext(); return
  end
  if g_game.canPerformGameAction and not g_game.canPerformGameAction() then
    scheduleNext(); return
  end

  local lp = g_game.getLocalPlayer and g_game.getLocalPlayer() or nil
  local hp = getPercent(lp, "hp")
  local mp = getPercent(lp, "mp")
  local manaCur, manaMax = getManaAbs(lp)

  -- HUD (throttled)
  do
    local nextHud = G._nextHudMs or 0
    if t >= nextHud then
      G._nextHudMs = t + (tonumber(CFG.hudUpdateMs) or 250)

      local hpTxt = (type(hp) == "number") and string.format("%.0f%%", hp) or "?"
      local mpTxt = "?"
      if type(manaCur) == "number" and type(manaMax) == "number" then
        mpTxt = string.format("%d/%d", manaCur, manaMax)
      elseif type(mp) == "number" then
        mpTxt = string.format("%.0f%%", mp)
      end

      local txt = string.format("GoL  HP: %s  MP: %s", hpTxt, mpTxt)

      -- Update in-window label (always, if UI exists)
      local win = ensureWindow()
      if win then
        local whud = getUiChild(win, "winHudLabel")
        if whud then pcall(function() whud:setText(txt) end) end
      end

      -- Update on-screen overlay (optional)
      if CFG.hudEnabled then
        local hud = ensureHudLabel()
        if hud then pcall(function() hud:setText(txt) end) end
      end
    end
  end

  -- Pause status (v10a) + global guard (skip actions while paused)
  local pinfo = (type(G.getPauseInfo) == "function") and G.getPauseInfo() or { paused = false }
  do
    local win = ensureWindow()
    if win then pcall(updatePauseStatus, win, pinfo) end
  end
	  -- NOTE: pause should not block life-safety (heal/mana). It only blocks loot and other non-critical actions.
	  local paused = (pinfo and pinfo.paused == true) and true or false

	  -- Emergency safety (heal/mana even if user toggles are OFF)
	  local safety = (type(CFG.safety) == "table") and CFG.safety or {}
	  local safetyEnabled = (safety.enabled ~= false)
	  local emergencyHealPct = tonumber(safety.emergencyHealPct)
	  local emergencyManaStartPct = tonumber(safety.emergencyManaStartPct)
	  local emergencyManaStopPct  = tonumber(safety.emergencyManaStopPct)
	  local emergencyManaStartMana = tonumber(safety.emergencyManaStartMana)
	  local emergencyManaStopMana  = tonumber(safety.emergencyManaStopMana)

	  local emergencyHeal = false
	  if safetyEnabled and type(hp) == "number" and type(emergencyHealPct) == "number" then
	    emergencyHeal = (hp <= emergencyHealPct)
	  end

	  local emergencyMana = false
	  if safetyEnabled then
	    if type(manaCur) == "number" and type(emergencyManaStartMana) == "number" then
	      emergencyMana = (manaCur <= emergencyManaStartMana)
	    elseif type(mp) == "number" and type(emergencyManaStartPct) == "number" then
	      emergencyMana = (mp <= emergencyManaStartPct)
	    end
	  end

	  -- Throttled safety log (so you immediately see it's protecting you)
	  if (emergencyHeal or emergencyMana) then
	    local nextLog = tonumber(G._nextSafetyLogMs) or 0
	    if t >= nextLog then
	      G._nextSafetyLogMs = t + 3000
	      if emergencyHeal then pushUiLog("SAFETY: emergency HEAL active") end
	      if emergencyMana then pushUiLog("SAFETY: emergency MANA active") end
	    end
	  end




	-- Heal
	  local healEnabled = (G.flags.heal == true)
	  if (healEnabled or emergencyHeal) and (t - (G._lastSpellMs or 0) >= (tonumber(CFG.spellCooldownMs) or 850)) then
    if type(hp) == "number" then
      if hp <= (tonumber(CFG.hpExuraVitaPct) or 0) then
        castSpell(CFG.spellExuraVita); G._lastSpellMs = t
      elseif hp <= (tonumber(CFG.hpExuraGranPct) or 0) then
        castSpell(CFG.spellExuraGran); G._lastSpellMs = t
      elseif hp <= (tonumber(CFG.hpExuraPct) or 0) then
        castSpell(CFG.spellExura); G._lastSpellMs = t
      end
    end
  end

  -- Mana
	  local manaEnabled = (G.flags.mana == true)
	  if (manaEnabled or emergencyMana) then
    if mp or manaCur then
      if G._drinking == nil then G._drinking = false end

      local useAbs = (type(manaCur) == "number") and (
        type(CFG.manaStartMana) == "number" or type(CFG.manaStopMana) == "number" or
        type(CFG.manaStartManaMin) == "number" or type(CFG.manaStartManaMax) == "number" or
        type(CFG.manaStopManaMin) == "number" or type(CFG.manaStopManaMax) == "number"
      )

	      local useEmergencyTargets = (emergencyMana == true) and (manaEnabled ~= true)
	      if not useEmergencyTargets then
	        ensureManaTargets(useAbs)
	      end

      local value = useAbs and manaCur or mp
      if type(value) == "number" then
	        local startT = useEmergencyTargets and (useAbs and emergencyManaStartMana or emergencyManaStartPct) or G._manaStartTarget
	        local stopT  = useEmergencyTargets and (useAbs and emergencyManaStopMana  or emergencyManaStopPct)  or G._manaStopTarget
	        -- Emergency fallback: if stop target is not provided, derive a safe stop threshold.
	        if useEmergencyTargets and type(stopT) ~= "number" and type(startT) == "number" then
	          if useAbs then
	            stopT = startT + 200
	          else
	            stopT = math.min(99, startT + 20)
	          end
	        end

        if (not G._drinking) and type(startT) == "number" and value <= startT then
          G._drinking = true
        elseif G._drinking and type(stopT) == "number" and value >= stopT then
          G._drinking = false
	          if not useEmergencyTargets then
	            G._manaStartTarget, G._manaStopTarget = nil, nil
	          end
        end

	        if (not useAbs) and G._drinking and type(mp) == "number" and mp >= 99 then
	          G._drinking = false
	          if not useEmergencyTargets then
	            G._manaStartTarget, G._manaStopTarget = nil, nil
	          end
	        end
      end

      if G._drinking and (t - (G._lastPotionMs or 0) >= (tonumber(CFG.potionCooldownMs) or 900)) then
        drinkPotion(lp, t)
        G._lastPotionMs = t

        if type(CFG.potionCooldownJitterMs) == "table" then
          local jmin = tonumber(CFG.potionCooldownJitterMs[1])
          local jmax = tonumber(CFG.potionCooldownJitterMs[2])
          local j = randBetween(jmin, jmax) or 0
          CFG.potionCooldownMs = math.max(150, (tonumber(CFG.potionCooldownMs) or 900) + j)
        end
      end
    end
  end

	  -- Loot (paused blocks loot)
	  if not paused then
	    doLootTick(t)
	  end

  scheduleNext()
end

-- ========== WINDOW ==========
local function updateToggleButton(win, id, onText, offText, onColor, offColor, enabled)
  if not win then return end
  local ok, b = callAny(win, "recursiveGetChildById", id)
  if not ok or not b then
    ok, b = callAny(win, "getChildById", id)
  end
  if not b then return end

  if enabled then
    pcall(function() b:setText(onText) end)
    if onColor then pcall(function() b:setBackgroundColor(onColor) end) end
  else
    pcall(function() b:setText(offText) end)
    if offColor then pcall(function() b:setBackgroundColor(offColor) end) end
  end
end

updateQuickButtons = function(win)
  if not win then return end

  local hudBtn = getUiChild(win, "hudToggleButton")
  if hudBtn then
    local on = not not (CFG and CFG.hudEnabled)
    pcall(function() hudBtn:setText(on and "HUD: ON" or "HUD: OFF") end)
    pcall(function() hudBtn:setBackgroundColor(on and "#00AA00cc" or "#333333cc") end)
  end

  local modeBtn = getUiChild(win, "lootModeButton")
  if modeBtn then
    local mode = (CFG and CFG.loot and CFG.loot.mode) or "list"
    mode = tostring(mode):lower()
    local txt = (mode == "all") and "Mode: ALL" or "Mode: LIST"
    pcall(function() modeBtn:setText(txt) end)
    pcall(function() modeBtn:setBackgroundColor("#333333cc") end)
  end
end

-- ========== CLEAN SHUTDOWN (RELOAD-SAFE) ==========
local HOTKEYS = { "F6", "F7", "F8", "Shift+F6" }

local function tryUnbindKey(key, scope)
  if not g_keyboard then return end

  local fn = g_keyboard.unbindKeyDown
  if type(fn) == "function" then
    local ok = pcall(fn, key, scope)
    if ok then return end
    pcall(fn, key)
    return
  end

  fn = g_keyboard.unbindKeyPress
  if type(fn) == "function" then
    local ok = pcall(fn, key, scope)
    if ok then return end
    pcall(fn, key)
    return
  end

  fn = g_keyboard.unbindKey
  if type(fn) == "function" then
    local ok = pcall(fn, key, scope)
    if ok then return end
    pcall(fn, key)
    return
  end
end

local function destroyWidgetSafe(w)
  if widgetAlive(w) then
    pcall(function() w:destroy() end)
  end
end

function _G.GiftOfLife.printPaths()
  local wd = (g_resources and type(g_resources.getWorkDir) == "function" and g_resources.getWorkDir()) or ""
  local wr = (g_resources and type(g_resources.getWriteDir) == "function" and g_resources.getWriteDir()) or ""
  print(string.format("[GoL] workDir=%s writeDir=%s stateVFS=%s stateABS=%s", tostring(wd), tostring(wr), tostring(G._statePath), tostring(G._stateAbsPath)))
end

function _G.GiftOfLife.shutdown()
  -- Stop loop + scheduled tick
  pcall(stopLoop)
  if G._evt and removeEvent then pcall(function() removeEvent(G._evt) end) end
  G._evt = nil
  G.enabled = false

  -- Cancel module-scoped scheduled events to avoid leaked widget references.
  if removeEvent then
    if G._winPollEv then pcall(removeEvent, G._winPollEv); G._winPollEv = nil end
    if G._minBtnWatchEv then pcall(removeEvent, G._minBtnWatchEv); G._minBtnWatchEv = nil end
    if G._telemetryEv then pcall(removeEvent, G._telemetryEv); G._telemetryEv = nil end
  end



  -- Telemetry loop (v10b)
  if G._telemetryEv and removeEvent then pcall(function() removeEvent(G._telemetryEv) end) end
  G._telemetryEv = nil

  -- Unbind hotkeys (best-effort; API differs between OTClient forks)
  local scope = G._hotkeyScope
  for _, key in ipairs(HOTKEYS) do
    pcall(function() tryUnbindKey(key, scope) end)
  end
  G._hotkeysBound = false
  G._hotkeyScope = nil

  -- Destroy HUD labels
  destroyWidgetSafe(G._hud)
  destroyWidgetSafe(G._statusLabel)
  G._hud = nil
  G._statusLabel = nil

  -- Also try by id (in case references were lost)
  local hp = getHudParent()
  if widgetAlive(hp) then
    local ok, w = pcall(function() return hp:recursiveGetChildById("GiftOfLifeHud") end)
    if ok then destroyWidgetSafe(w) end
    ok, w = pcall(function() return hp:recursiveGetChildById("GiftOfLifeStatus") end)
    if ok then destroyWidgetSafe(w) end
  end

  -- Destroy main window
  destroyWidgetSafe(G._window)
  G._window = nil

  -- Best-effort: destroy any leftover window by id under root
  local root = nil
  if modules and modules.game_interface and modules.game_interface.getRootPanel then
    local ok, r = pcall(modules.game_interface.getRootPanel)
    if ok then root = r end
  end
  if not root and g_ui and g_ui.getRootWidget then
    root = g_ui.getRootWidget()
  end
  if widgetAlive(root) then
    local ok, w = pcall(function() return root:recursiveGetChildById("giftOfLifeWindow") end)
    if ok then destroyWidgetSafe(w) end
  end

  -- Keep logs + config in memory, but clear volatile runtime state
  G._tick = nil
  G._drinking = false
  G._lastSpellMs = 0
  G._lastPotionMs = 0

  -- Final best-effort purge (by ids/prefixes + tracked weak registry).
  if _G.GoLLeakGuard and type(_G.GoLLeakGuard.purge) == "function" then
    pcall(_G.GoLLeakGuard.purge)
  end

end



-- ========== LOOT LIST (UI) ==========
local function formatIdList(ids, maxShown)
  if type(ids) ~= "table" or #ids == 0 then return "IDs: (empty)" end
  maxShown = tonumber(maxShown) or 25
  local n = #ids
  local first = math.max(1, n - maxShown + 1)
  local parts = {}
  for i = first, n do
    parts[#parts+1] = tostring(ids[i])
  end
  local suffix = (n > maxShown) and string.format("  (+%d more)", n - maxShown) or ""
  return string.format("IDs (%d): %s%s", n, table.concat(parts, ", "), suffix)
end

local function updateLootListUi(win)
  if not win then return end
  local lab = getUiChild(win, "lootListLabel")
  if not lab then return end

  local maxShown = (CFG and CFG.ui and CFG.ui.maxLootIdsShown) or 25
  local lootIds = (CFG and CFG.loot and CFG.loot.itemIds) or {}
  local noLootIds = (CFG and CFG.loot and CFG.loot.ignoreIds) or {}

  -- Normalize once more in case lists came from older configs as a set/map.
  lootIds = _golNormalizeIdList(lootIds)
  noLootIds = _golNormalizeIdList(noLootIds)
  if CFG and CFG.loot then
    CFG.loot.itemIds = lootIds
    CFG.loot.ignoreIds = noLootIds
  end

  local lootLine = formatIdList(lootIds, maxShown)
  local noLootLine = formatIdList(noLootIds, maxShown)

  -- Rename prefixes for clarity.
  if lootLine:sub(1, 3) == "IDs" then lootLine = "Loot " .. lootLine end
  if noLootLine:sub(1, 3) == "IDs" then noLootLine = "Ignore " .. noLootLine end

  pcall(function() lab:setText(lootLine .. "\n" .. noLootLine) end)
end


-- ========== PROFILES (first-run picker + spell rotation templates) ==========
local function pathExistsLite(path)
  if type(path) ~= 'string' or path == '' then return false end
  if g_resources and type(g_resources.fileExists) == 'function' then
    local ok, ex = pcall(g_resources.fileExists, path)
    if ok and ex then return true end
  end
  if g_resources and type(g_resources.readFileContents) == 'function' then
    local ok, data = pcall(g_resources.readFileContents, path)
    if ok and type(data) == 'string' and #data > 0 then return true end
  end
  if io and io.open then
    local f = io.open(path, 'r')
    if f then f:close(); return true end
  end
  return false
end

local function updateProfileLabel(win)
  if not win then win = G._window end
  if not win then return end
  local lab = getUiChild(win, "profileLabel")
  if not lab then return end
  local p = (CFG and CFG.activeProfile) or "default"
  pcall(function() lab:setText("Profil aktywny: " .. tostring(p)) end)
end

local function loadBuiltinProfiles()
  local candidates = {
    "gift_of_life_profiles.lua",
    "gift_of_life/gift_of_life_profiles.lua",
    "modules/gift_of_life/gift_of_life_profiles.lua",
  }
  for _, p in ipairs(candidates) do
    if pathExistsLite(p) then
      local ok, prof = pcall(dofile, p)
      if ok and type(prof) == "table" then return prof end
    end
  end
  return {}
end

local function getAllProfileNames()
  local names = {}
  local seen = {}
  if CFG and type(CFG.profiles) == "table" then
    for k, _ in pairs(CFG.profiles) do
      if type(k) == "string" and k ~= "" and not seen[k] then
        seen[k] = true
        table.insert(names, k)
      end
    end
  end
  if not seen["default"] then table.insert(names, "default") end

  table.sort(names)

  -- Keep "default" first if present.
  if #names > 1 then
    for i = 1, #names do
      if names[i] == "default" then
        table.remove(names, i)
        table.insert(names, 1, "default")
        break
      end
    end
  end
  return names
end

local function bootstrapRotationProfiles()
  -- Auto-create dynamic profiles (persisted into state) for built-in rotation templates,
  -- but ONLY when they are not already present in config.lua profiles.
  local builtins = loadBuiltinProfiles()
  if type(builtins) ~= "table" then return false end

  local cfgProfiles = (CFG and type(CFG.__configProfiles) == "table" and CFG.__configProfiles) or {}
  local dyn = (CFG and type(CFG.dynamicProfiles) == "table" and CFG.dynamicProfiles) or {}
  local added = 0

  for name, prof in pairs(builtins) do
    if type(name) == "string" and name:sub(1, 9) == "rotation_" then
      if cfgProfiles[name] == nil and dyn[name] == nil and type(prof) == "table" then
        dyn[name] = prof
        added = added + 1
      end
    end
  end

  if added > 0 then
    CFG.dynamicProfiles = dyn
    CFG.profiles = CFG.profiles or {}
    for name, prof in pairs(dyn) do
      if CFG.profiles[name] == nil then
        CFG.profiles[name] = prof
      end
    end
    pcall(requestSaveConfig)
    return true
  end

  return false
end

local function ensureProfilePickerWindow()
  if widgetAlive(G._profilePicker) then return G._profilePicker end
  local root = g_ui and g_ui.getRootWidget and g_ui.getRootWidget() or nil
  if not root or not (g_ui and g_ui.loadUI) then return nil end

  local picker = nil
  local function tryLoad(path)
    local ok, w = pcall(function() return g_ui.loadUI(path, root) end)
    if ok and w and widgetAlive(w) then picker = w; return true end
    return false
  end

  local candidates = {
    "gift_of_life_profile_picker.otui",
    "gift_of_life/gift_of_life_profile_picker.otui",
    "modules/gift_of_life/gift_of_life_profile_picker.otui",
    "gift_of_life_profile_picker_fallback.otui",
    "gift_of_life/gift_of_life_profile_picker_fallback.otui",
    "modules/gift_of_life/gift_of_life_profile_picker_fallback.otui",
  }

  for _, p in ipairs(candidates) do
    if tryLoad(p) then break end
  end

  if not picker then return nil end
  G._profilePicker = picker
  safeTrackWidget(picker)
  local names = getAllProfileNames()
  local cur = (CFG and CFG.activeProfile) or "default"
  if type(picker._golSelectedProfile) ~= "string" or picker._golSelectedProfile == "" then
    picker._golSelectedProfile = cur
  end

  local combo = getUiChild(picker, "profileCombo")
  if combo then
    pcall(function() combo:clearOptions() end)
    for _, n in ipairs(names) do
      pcall(function() combo:addOption(n) end)
    end
    pcall(function() combo:setCurrentOption(picker._golSelectedProfile) end)
  end

  local list = getUiChild(picker, "profileList")
  if list and g_ui and g_ui.createWidget then
    -- Rebuild list buttons (combo-free fallback for forks with broken popup menus).
    pcall(function()
      local kids = list:getChildren()
      if kids then
        for _, c in ipairs(kids) do
          if c and type(c.destroy) == "function" then c:destroy() end
        end
      end
    end)

    picker._golProfileButtons = {}
    local function refreshProfileButtons()
      local sel = picker._golSelectedProfile or cur
      for _, b in ipairs(picker._golProfileButtons) do
        local n = b._golProfileName
        local prefix = (n == sel) and "[*] " or "[ ] "
        pcall(function() b:setText(prefix .. tostring(n)) end)
      end
    end

    for _, n in ipairs(names) do
      local btn = nil
      local ok, w = pcall(function() return g_ui.createWidget("GoLProfileItem", list) end)
      if ok and w and widgetAlive(w) then
        btn = w
      else
        ok, w = pcall(function() return g_ui.createWidget("GoLPickerButton", list) end)
        if ok and w and widgetAlive(w) then btn = w end
      end
      if btn then
        btn._golProfileName = n
        btn.onClick = function()
          picker._golSelectedProfile = n
          refreshProfileButtons()
        end
        table.insert(picker._golProfileButtons, btn)
      end
    end

    refreshProfileButtons()
  end

  
  -- v11E: profile picker tooltips (combo-free)
  safeSetTooltip(getUiChild(picker, "profileCombo"), "Select active profile.")
  safeSetTooltip(getUiChild(picker, "profileList"), "Select active profile.")
  safeSetTooltip(getUiChild(picker, "applyButton"), "Apply selected profile and reload.")
  safeSetTooltip(getUiChild(picker, "cancelButton"), "Close without changes.")
local cancelBtn = getUiChild(picker, "cancelButton")
  if cancelBtn then
    cancelBtn.onClick = function()
      safeDestroyWidget(picker, "profilePicker:cancel")
      G._profilePicker = nil
      return true
    end
  end

  pcall(function()
    picker.onClose = function()
      safeDestroyWidget(picker, "profilePicker:onClose")
      G._profilePicker = nil
      return true
    end
  end)


  local applyBtn = getUiChild(picker, "applyButton")
  if applyBtn then
    applyBtn.onClick = function()
      local sel = nil
      if type(picker._golSelectedProfile) == "string" and picker._golSelectedProfile ~= "" then
        sel = picker._golSelectedProfile
      end
      if (type(sel) ~= "string" or sel == "") and combo and type(combo.getCurrentOption) == "function" then
        local ok, v = pcall(combo.getCurrentOption, combo)
        if ok then sel = v end
      end
      if type(sel) ~= "string" or sel == "" then
        sel = (CFG and CFG.activeProfile) or "default"
      end

      CFG.activeProfile = sel
      CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
      CFG.ui.firstRunDone = true

      -- If user picked rotation profile => auto-enable the addon (as requested).
      if type(sel) == "string" and sel:sub(1, 9) == "rotation_" then
        CFG.addonsEnabled = true
        CFG.addons = (type(CFG.addons) == "table") and CFG.addons or {}
        CFG.addons.autospell_rotation = (type(CFG.addons.autospell_rotation) == "table") and CFG.addons.autospell_rotation or {}
        CFG.addons.autospell_rotation.enabled = true
      end

      updateProfileLabel(G._window)

      -- Persist + reload (so addons pick up the profile cleanly).
      pcall(requestSaveConfig)

      safeDestroyWidget(picker, "profilePicker:apply")
      G._profilePicker = nil

      if scheduleEvent then
        scheduleEvent(function()
          pcall(function() dofile("gift_of_life/init.lua") end)
          pcall(function() dofile("gift_of_life/gift_of_life/init.lua") end)
          pcall(function() dofile("modules/gift_of_life/init.lua") end)
        end, 600)
      else
        pcall(function() dofile("gift_of_life/init.lua") end)
      end
    end
  end

  return picker
end


-- ========== ROTATION EDITOR (spells) ==========
-- Simple multiline editor that persists into gift_of_life_state.lua:
--   CFG.dynamicProfiles[activeProfile].spellRotation.spells

local function _rotTrim(s)
  s = tostring(s or "")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function _rotSetStatus(win, ok, msg)
  if not win then return end
  local lbl = getUiChild(win, "rotationStatusLabel")
  if not lbl then return end

  pcall(function() lbl:setText(msg or "") end)
  local color = ok and "#00ff00" or "#ff5555"
  if type(lbl.setColor) == "function" then
    pcall(function() lbl:setColor(color) end)
  elseif type(lbl.setTextColor) == "function" then
    pcall(function() lbl:setTextColor(color) end)
  end
end

local function _rotGetActiveProfile()
  local p = (CFG and CFG.activeProfile) or "default"
  if type(p) ~= "string" or p == "" then p = "default" end
  return p
end

local function _rotEnsureProfileSpellRotation()
  CFG.dynamicProfiles = (type(CFG.dynamicProfiles) == "table") and CFG.dynamicProfiles or {}
  local p = _rotGetActiveProfile()
  local prof = CFG.dynamicProfiles[p]
  if type(prof) ~= "table" then
    prof = {}
    CFG.dynamicProfiles[p] = prof
  end

  prof.spellRotation = (type(prof.spellRotation) == "table") and prof.spellRotation or {}
  prof.spellRotation.spells = (type(prof.spellRotation.spells) == "table") and prof.spellRotation.spells or {}
  return prof.spellRotation
end

local function _rotFormatSpells(list)
  if type(list) ~= "table" then return "" end
  local lines = {}

  for _, e in ipairs(list) do
    if type(e) == "table" then
      local base = ""
      if type(e.text) == "string" and e.text ~= "" then
        base = e.text
      elseif type(e.hotkey) == "string" and e.hotkey ~= "" then
        base = "hotkey=" .. e.hotkey
      end

      if base ~= "" then
        local parts = { base }

        local cd = tonumber(e.cooldownMs)
        if cd then parts[#parts + 1] = "cd=" .. tostring(math.floor(cd)) end

        local mp = tonumber(e.minManaPct)
        if mp then parts[#parts + 1] = "mp>=" .. tostring(math.floor(mp)) end

        local hp = tonumber(e.maxHpPct)
        if hp then parts[#parts + 1] = "hp<=" .. tostring(math.floor(hp)) end

        local t = tonumber(e.minTargets)
        if t then parts[#parts + 1] = "targets>=" .. tostring(math.floor(t)) end

        if e.enabled == false then parts[#parts + 1] = "enabled=0" end

        if type(e.hotkey) == "string" and e.hotkey ~= "" and not base:lower():match("^hotkey%s*=") then
          parts[#parts + 1] = "hotkey=" .. e.hotkey
        end

        lines[#lines + 1] = table.concat(parts, " | ")
      end
    end
  end

  return table.concat(lines, "\n")
end

local function _rotParseEditorText(text)
  local spells = {}
  text = tostring(text or "")

  local lineNo = 0
  for line in text:gmatch("[^\r\n]+") do
    lineNo = lineNo + 1
    line = _rotTrim(line)

    if line ~= "" and not line:match("^#") and not line:match("^%-%-") then
      local parts = {}
      for seg in line:gmatch("[^|]+") do
        parts[#parts + 1] = _rotTrim(seg)
      end

      local head = parts[1] or ""
      if head == "" then
        return nil, "Line " .. lineNo .. ": missing spell text"
      end

      local entry = { enabled = true }

      if head:lower():match("^hotkey%s*=") then
        entry.hotkey = _rotTrim(head:match("^%s*[Hh][Oo][Tt][Kk][Ee][Yy]%s*=%s*(.-)%s*$") or "")
      else
        entry.text = head
      end

      for i = 2, #parts do
        local tok = _rotTrim(parts[i])
        if tok ~= "" then
          local low = tok:lower()
          local num = nil

          if low:match("^cd%s*=") or low:match("^cooldown%s*=") then
            num = tonumber(tok:match("=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid cd" end
            entry.cooldownMs = num

          elseif low:match("^mp%s*>=") then
            num = tonumber(tok:match(">=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid mp>=" end
            entry.minManaPct = num

          elseif low:match("^minmana%s*=") then
            num = tonumber(tok:match("=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid minmana" end
            entry.minManaPct = num

          elseif low:match("^hp%s*<=") then
            num = tonumber(tok:match("<=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid hp<=" end
            entry.maxHpPct = num

          elseif low:match("^maxhp%s*=") then
            num = tonumber(tok:match("=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid maxhp" end
            entry.maxHpPct = num

          elseif low:match("^targets%s*>=") then
            num = tonumber(tok:match(">=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid targets>=" end
            entry.minTargets = num

          elseif low:match("^mintargets%s*=") then
            num = tonumber(tok:match("=%s*(%d+)"))
            if not num then return nil, "Line " .. lineNo .. ": invalid mintargets" end
            entry.minTargets = num

          elseif low:match("^enabled%s*=") then
            local v = tok:match("=%s*(%d+)")
            if v == "0" then entry.enabled = false
            elseif v == "1" then entry.enabled = true
            else return nil, "Line " .. lineNo .. ": invalid enabled (use 0/1)" end

          elseif low:match("^hotkey%s*=") then
            entry.hotkey = _rotTrim(tok:match("=%s*(.-)%s*$") or "")

          else
            return nil, "Line " .. lineNo .. ": unknown token '" .. tok .. "'"
          end
        end
      end

      if (type(entry.text) ~= "string" or entry.text == "") and (type(entry.hotkey) ~= "string" or entry.hotkey == "") then
        return nil, "Line " .. lineNo .. ": missing spell text/hotkey"
      end

      spells[#spells + 1] = entry
    end
  end

  return spells, nil
end

local function ensureRotationEditorWindow()
  if widgetAlive(G._rotationEditorWin) then return G._rotationEditorWin end

  local root = g_ui and g_ui.getRootWidget and g_ui.getRootWidget() or nil
  if not root or not (g_ui and g_ui.loadUI) then return nil end

  local win = nil
  local function tryLoad(path)
    local ok, w = pcall(function() return g_ui.loadUI(path, root) end)
    if ok and w and widgetAlive(w) then win = w; return true end
    return false
  end

  local candidates = {
    "gift_of_life_rotation_editor.otui",
    "gift_of_life/gift_of_life_rotation_editor.otui",
    "modules/gift_of_life/gift_of_life_rotation_editor.otui",
    "gift_of_life_rotation_editor_fallback.otui",
    "gift_of_life/gift_of_life_rotation_editor_fallback.otui",
    "modules/gift_of_life/gift_of_life_rotation_editor_fallback.otui",
  }

  for _, p in ipairs(candidates) do
    if tryLoad(p) then break end
  end

  if not win then return nil end

  G._rotationEditorWin = win
  safeTrackWidget(win)

  
  -- v11E: rotation editor tooltips
  safeSetTooltip(getUiChild(win, "rotationEditText"),
    "One line = one action. Example: exori gran | cd=1200 | mp>=20 | hp<=90 | targets>=2 | enabled=1")
  safeSetTooltip(getUiChild(win, "rotationSaveButton"), "Parse and save to current profile.")
  safeSetTooltip(getUiChild(win, "rotationCancelButton"), "Close without saving.")
local cancelBtn = getUiChild(win, "rotationCancelButton")
  if cancelBtn then
    cancelBtn.onClick = function()
      safeDestroyWidget(win, "rotationEditor:cancel")
      G._rotationEditorWin = nil
      return true
    end
  end

  pcall(function()
    win.onClose = function()
      safeDestroyWidget(win, "rotationEditor:onClose")
      G._rotationEditorWin = nil
      return true
    end
  end)


  local saveBtn = getUiChild(win, "rotationSaveButton")
  if saveBtn then
    saveBtn.onClick = function()
      local edit = getUiChild(win, "rotationEditText")
      local text = ""
      if edit and type(edit.getText) == "function" then
        local ok, t = pcall(edit.getText, edit)
        if ok then text = t or "" end
      end

      local spells, err = _rotParseEditorText(text)
      if not spells then
        _rotSetStatus(win, false, err or "Parse error")
        return
      end

      local sr = _rotEnsureProfileSpellRotation()
      sr.spells = spells
      sr.enabled = true

      -- Also enable the global spellRotation section (merge-friendly).
      CFG.spellRotation = (type(CFG.spellRotation) == "table") and CFG.spellRotation or {}
      CFG.spellRotation.enabled = true

      -- Ensure addon is enabled so it actually runs.
      CFG.addons = (type(CFG.addons) == "table") and CFG.addons or {}
      CFG.addons.autospell_rotation = (type(CFG.addons.autospell_rotation) == "table") and CFG.addons.autospell_rotation or {}
      CFG.addons.autospell_rotation.enabled = true

      -- Persist state (gift_of_life_state.lua).
      if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end

      -- Try to activate addon immediately (if addon manager is loaded).
      if _G.GoLAddons then
        if type(_G.GoLAddons.enable) == "function" then
          pcall(_G.GoLAddons.enable, "autospell_rotation")
        elseif type(_G.GoLAddons.reloadEnabled) == "function" then
          pcall(_G.GoLAddons.reloadEnabled, { purge = false })
        end
      end

      _rotSetStatus(win, true, "Saved: " .. tostring(#spells) .. " lines")
      safeDestroyWidget(win, "rotationEditor:save")
      G._rotationEditorWin = nil
    end
  end

  return win
end

local function openRotationEditor()
  local win = ensureRotationEditorWindow()
  if not win then return end

  local edit = getUiChild(win, "rotationEditText")
  local pName = _rotGetActiveProfile()

  local prof =
    (CFG and type(CFG.dynamicProfiles) == "table" and CFG.dynamicProfiles[pName]) or
    (CFG and type(CFG.profiles) == "table" and CFG.profiles[pName]) or
    {}

  local sr = (type(prof) == "table" and type(prof.spellRotation) == "table") and prof.spellRotation or {}
  local spells = (type(sr.spells) == "table") and sr.spells or {}

  if edit and type(edit.setText) == "function" then
    pcall(edit.setText, edit, _rotFormatSpells(spells))
  end

  _rotSetStatus(win, true, "Loaded profile: " .. tostring(pName))
  pcall(function() win:show(); win:raise(); win:focus() end)
end


local function showProfilePickerIfFirstRun()
  -- Make sure rotation templates exist for editing (persisted).
  pcall(bootstrapRotationProfiles)

  local firstDone = (CFG and type(CFG.ui) == "table" and CFG.ui.firstRunDone == true)
  if firstDone then return end

  local picker = ensureProfilePickerWindow()
  if picker and widgetAlive(picker) then
    pcall(function() picker:raise() end)
    pcall(function() picker:show() end)
  end
end


local function addonIsEnabled(name)
  if not (CFG and type(CFG.addons) == "table") then return false end
  local e = CFG.addons[name]
  return type(e) == "table" and e.enabled == true
end

local function updateAddonButtons(win)
  if not win then win = G._window end
  if not win then return end

  local map = {
    panic_guard = { id = "addon_panic_guard", label = "Panic Guard" },
    smart_target = { id = "addon_smart_target", label = "Smart Target" },
    combat_modes = { id = "addon_combat_modes", label = "Combat Modes" },
    smart_kite = { id = "addon_smart_kite", label = "Smart Kite" },
    autospell_rotation = { id = "addon_autospell_rotation", label = "Rotation" },
  }

  for name, info in pairs(map) do
    local b = getUiChild(win, info.id)
    if b then
      safeSetTooltip(b, "Toggle addon: " .. (info.label or name))

      local on = addonIsEnabled(name)
      local txt = string.format("%s: %s", info.label, on and "ON" or "OFF")
      pcall(function() b:setText(txt) end)
      pcall(function() b:setBackgroundColor(on and "#006400cc" or "#8B0000cc") end)
    end
  end
end



updatePauseStatus = function(win, info)
  if not win then win = G._window end
  if not win then return end

  local label = getUiChild(win, "pauseStatusLabel")
  if not label then return end

  if not info and type(G.getPauseInfo) == "function" then
    info = G.getPauseInfo()
  end
  info = info or { paused = false }

  if info.paused == true then
    local sec = math.ceil((tonumber(info.remainingMs) or 0) / 1000)
    local reason = tostring(info.reason or "paused")
    local src = tostring(info.source or "")
    local cnt = tonumber(info.count) or 1
    local prefix = (cnt and cnt > 1) and string.format("PAUSED(%d): ", cnt) or "PAUSED: "
    local txt = string.format("%s%s (%ds)", prefix, reason, sec)
    if src ~= "" and src ~= "nil" then
      txt = txt .. string.format(" [%s]", src)
    end
    pcall(function() label:setText(txt) end)
    pcall(function() label:setBackgroundColor("#8B0000cc") end)
  else
    pcall(function() label:setText("STATUS: RUNNING") end)
    pcall(function() label:setBackgroundColor("#006400cc") end)
  end
end



-- ========== TELEMETRY (v10b) ==========
local function updateDebugButton(win)
  if not win then win = G._window end
  if not win then return end
  local b = getUiChild(win, "debugToggleButton")
  if not b then return end

  local on = (G.ui and G.ui.debugVisible == true)
  pcall(function() b:setText(on and "Debug: ON" or "Debug: OFF") end)
  pcall(function() b:setBackgroundColor(on and "#1E90FFcc" or "#333333cc") end)
end

-- Manual pause button (v10d)
local function manualPauseActive()
  local stack = G._pauseStack
  if type(stack) ~= "table" then return false end
  local e = stack["manual"]
  if type(e) ~= "table" then return false end
  local t = nowMs()
  return t < (tonumber(e.untilMs) or 0)
end

local function updatePauseButton(win)
  if not win then win = G._window end
  if not win then return end
  local b = getUiChild(win, "pauseToggleButton")
  if not b then return end

  local on = manualPauseActive()
  if on then
    pcall(function() b:setText("Resume") end)
    pcall(function() b:setBackgroundColor("#8B0000cc") end)
  else
    pcall(function() b:setText("Pause: 10s") end)
    pcall(function() b:setBackgroundColor("#333333cc") end)
  end
end

local function enabledAddonsString()
  if not (CFG and type(CFG.addons) == "table") then return "-" end
  local parts = {}
  for k, v in pairs(CFG.addons) do
    if type(v) == "table" and v.enabled == true then
      parts[#parts+1] = tostring(k)
    end
  end
  table.sort(parts)
  if #parts == 0 then return "-" end
  local maxShown = 5
  local shown = {}
  for i = 1, math.min(maxShown, #parts) do
    shown[#shown+1] = parts[i]
  end
  local more = #parts - #shown
  local s = table.concat(shown, ", ")
  if more > 0 then s = s .. string.format(" (+%d)", more) end
  return s
end

local function getTargetName()
  if not g_game then return "-" end
  local c = nil
  if type(g_game.getAttackingCreature) == "function" then
    local ok, r = pcall(g_game.getAttackingCreature)
    if ok then c = r end
  end
  if not c and type(g_game.getAttackingCreature) == "function" then
    local ok, r = pcall(function() return g_game:getAttackingCreature() end)
    if ok then c = r end
  end
  if c then
    local ok, name = callAny(c, "getName")
    if ok and name and name ~= "" then return tostring(name) end
  end
  return "-"
end

local function updateTelemetryUi(win)
  if not win then win = G._window end
  if not win then return end

  local panel = getUiChild(win, "telemetryPanel")
  local lab = getUiChild(win, "telemetryLabel")
  if not panel or not lab then return end

  local dbgOn = (G.ui and G.ui.debugVisible == true)
  if not dbgOn then
    pcall(function() lab:setText("Debug: OFF (click Debug: ON)") end)
    return
  end

  local t = nowMs()
  local nextMs = tonumber(G._telemetryNextMs or 0) or 0
  if t < nextMs then return end

  local updateEvery = 350
  if CFG and CFG.ui and tonumber(CFG.ui.telemetryUpdateMs) then
    updateEvery = math.max(120, tonumber(CFG.ui.telemetryUpdateMs))
  end
  G._telemetryNextMs = t + updateEvery

  local pinfo = (type(G.getPauseInfo) == "function") and G.getPauseInfo() or { paused = false }

  local lp = g_game.getLocalPlayer and g_game.getLocalPlayer() or nil
  local hp = getPercent(lp, "hp")
  local mp = getPercent(lp, "mp")
  local manaCur, manaMax = getManaAbs(lp)

  local hpTxt = (type(hp) == "number") and string.format("%.0f%%", hp) or "?"
  local mpTxt = (type(mp) == "number") and string.format("%.0f%%", mp) or "?"
  local mpAbs = "?"
  if type(manaCur) == "number" and type(manaMax) == "number" then
    mpAbs = string.format("%d/%d", manaCur, manaMax)
  end

  local uptime = math.floor((t - (tonumber(G._startMs or t) or t)) / 1000)
  local coreLine = string.format("Core: H=%s M=%s L=%s",
    (G.flags and G.flags.heal) and "ON" or "OFF",
    (G.flags and G.flags.mana) and "ON" or "OFF",
    (G.flags and G.flags.loot) and "ON" or "OFF"
  )

  local pauseLine = "RUNNING"
  if pinfo and pinfo.paused == true then
    local sec = math.ceil((tonumber(pinfo.remainingMs) or 0) / 1000)
    local reason = tostring(pinfo.reason or "paused")
    local src = tostring(pinfo.source or "")
    local cnt = tonumber(pinfo.count) or 1
    local prefix = (cnt and cnt > 1) and string.format("PAUSED(%d): ", cnt) or "PAUSED: "
    pauseLine = string.format("%s%s (%ds)", prefix, reason, sec)
    if src ~= "" and src ~= "nil" then
      pauseLine = pauseLine .. string.format(" [%s]", src)
    end
  end

  local last = (G.lastAction and tostring(G.lastAction) or "")
  local lastAge = 0
  if (tonumber(G.lastActionAtMs) or 0) > 0 then
    lastAge = math.max(0, math.floor((t - (tonumber(G.lastActionAtMs) or t)) / 1000))
  end
  local lastLine = (last ~= "") and string.format("Last: %s (%ds ago)", last, lastAge) or "Last: -"

  local lines = {
    string.format("Tick: %dms  Uptime: %ds", tonumber(CFG.tickMs) or 0, uptime),
    coreLine,
    pauseLine,
    string.format("HP: %s  MP: %s  (%s)", hpTxt, mpTxt, mpAbs),
    string.format("Target: %s", getTargetName()),
    string.format("Addons: %s", enabledAddonsString()),
  }

  -- Loot observability (shows only when loot tick runs at least once this session)
  if G._lootDbg then
    local ld = G._lootDbg
    lines[#lines + 1] = string.format("LootDbg: %s mode=%s srcItems=%s",
      (G.flags and G.flags.loot) and "ON" or "OFF",
      tostring(ld.mode or "?"),
      tostring(ld.srcItems or 0)
    )
    lines[#lines + 1] = string.format("Cap: %s (min=%s)", tostring(ld.cap or "-"), tostring((CFG and CFG.loot and CFG.loot.minCap) or 0))
    lines[#lines + 1] = "LootSrc: " .. tostring(ld.source or "none")

    local ll = "LootLast: " .. tostring(ld.last or "-")
    if tostring(ld.skip or "") ~= "" then ll = ll .. " | skip=" .. tostring(ld.skip) end
    if tostring(ld.err or "") ~= "" then ll = ll .. " | err=" .. tostring(ld.err) end
    lines[#lines + 1] = ll
  end

  lines[#lines + 1] = lastLine

  pcall(function() lab:setText(table.concat(lines, "\n")) end)
end


-- ========== ADDON AUDIT HARNESS (AAH) ==========
G._auditUi = G._auditUi or { rows = {}, nextMs = 0, dirty = true, filter = "ALL", expanded = {} }

local function _shortOneLine(s, maxLen)
  s = tostring(s or "")
  -- Normalize multi-line errors into a single line.
  -- NOTE: short literal strings cannot contain raw newlines; use escape sequences.
  s = s:gsub("\r", ""):gsub("\n", " | ")
  if maxLen and #s > maxLen then
    return s:sub(1, maxLen - 3) .. "..."
  end
  return s
end

local function _auditSnapshot()
  if _G.GoLAddons and type(_G.GoLAddons.getAuditSnapshot) == "function" then
    local ok, snap = pcall(_G.GoLAddons.getAuditSnapshot)
    if ok and type(snap) == "table" then return snap end
  end

  -- Fallback (minimal) if addon manager doesn't expose audit.
  local order = {}
  if CFG and type(CFG.addons) == "table" then
    for name, _ in pairs(CFG.addons) do
      if type(name) == "string" and name:sub(1,1) ~= "_" then order[#order+1] = name end
    end
    table.sort(order)
  end
  local audit = {}
  for _, name in ipairs(order0) do
    local enabled = (CFG and CFG.addons and type(CFG.addons[name]) == "table" and CFG.addons[name].enabled == true) or false
    local loaded = false
    if _G.GoLAddons and type(_G.GoLAddons.isLoaded) == "function" then
      local ok2, r2 = pcall(_G.GoLAddons.isLoaded, name)
      loaded = (ok2 and r2 == true)
    end
    audit[name] = { name = name, enabledInCfg = enabled, loaded = loaded }
  end
  return { nowMs = nowMs(), addonsEnabled = (CFG and CFG.addonsEnabled ~= false), order = order, audit = audit }
end

local function _auditSetLabelColor(w, color)
  if not w then return end
  if type(w.setColor) == "function" then pcall(function() w:setColor(color) end) return end
  if type(w.setTextColor) == "function" then pcall(function() w:setTextColor(color) end) return end
end

local function _auditSetBg(w, color)
  if not w then return end
  if type(w.setBackgroundColor) == "function" then pcall(function() w:setBackgroundColor(color) end) end
end



-- AAH PRO: deterministic status + sorting + filter + expand lastError
local _auditRank = { ERR = 1, CFG = 2, ON = 3, OFF = 4, DIS = 5 }

local function _auditStatusForSnap(snap, a)
  if snap and snap.addonsEnabled == false then return "DIS" end
  if a and a.loaded == true then return "ON" end
  if a and a.enabledInCfg == true then
    if a.lastError and tostring(a.lastError) ~= "" then return "ERR" end
    return "CFG"
  end
  return "OFF"
end

local function _auditSortedFilteredOrder(snap, order0, audit)
  order0 = (type(order0) == "table") and order0 or {}
  audit = (type(audit) == "table") and audit or {}

  local f = "ALL"
  if type(G._auditUi) == "table" then
    f = tostring(G._auditUi.filter or "ALL")
  end

  local items = {}
  for _, name in ipairs(order0) do
    local a = audit[name] or {}
    local st = _auditStatusForSnap(snap, a)
    if f == "ALL" or f == st then
      items[#items+1] = { name = name, status = st }
    end
  end

  table.sort(items, function(x, y)
    local rx = _auditRank[x.status] or 99
    local ry = _auditRank[y.status] or 99
    if rx ~= ry then return rx < ry end
    return tostring(x.name) < tostring(y.name)
  end)

  local out = {}
  for i, it in ipairs(items) do out[i] = it.name end
  return out
end
local scheduleDelay -- AAH timer (forward decl; closures must capture local)

local function updateAddonAuditUi(win, force)
  if not win then win = G._window end
  if not win then return end

  local panel = getUiChild(win, "addonAuditPanel")
  if not panel or (type(panel.isVisible) == "function" and not panel:isVisible()) then
    return
  end

  local dbgOn = (G.ui and G.ui.debugVisible == true)
  local txt = getUiChild(win, "addonAuditText")
  local list = getUiChild(win, "addonAuditList")
  if not txt or not list then return end

  if not dbgOn then
    pcall(function() txt:setText("Debug: OFF (click Debug: ON)") end)
    return
  end

  local t = nowMs()
  local every = 750
  if CFG and CFG.ui and tonumber(CFG.ui.addonAuditUpdateMs) then
    every = math.max(250, tonumber(CFG.ui.addonAuditUpdateMs))
  end
  if not force and t < (tonumber(G._auditUi.nextMs) or 0) and not (G._auditUi.dirty == true) then return end
  G._auditUi.nextMs = t + every
  G._auditUi.dirty = false

  local snap = _auditSnapshot()
  local order0 = (type(snap.order) == "table") and snap.order or {}
  local audit = (type(snap.audit) == "table") and snap.audit or {}
  local order = _auditSortedFilteredOrder(snap, order0, audit)

  local enabledCfg = 0
  local loadedCnt = 0
  local cfgCnt = 0
  local errCnt = 0
  for _, name in ipairs(order) do
    local a = audit[name] or {}
    if a.enabledInCfg == true then enabledCfg = enabledCfg + 1 end
    if a.loaded == true then loadedCnt = loadedCnt + 1 end
    local hasErr = (a.lastError and tostring(a.lastError) ~= "")
    if hasErr then errCnt = errCnt + 1 end
    if a.enabledInCfg == true and a.loaded ~= true and not hasErr then
      cfgCnt = cfgCnt + 1
    end
  end

    local f = (type(G._auditUi) == "table") and tostring(G._auditUi.filter or "ALL") or "ALL"
  local fbtn = getUiChild(win, "addonAuditFilterButton")
  if fbtn and type(fbtn.setText) == "function" then pcall(function() fbtn:setText("Filter: " .. f) end) end
local lines = {
    string.format("AddonsEnabled: %s", (snap.addonsEnabled == false) and "NO" or "YES"),
    string.format("Configured ON: %d  Loaded: %d  CFG: %d  ERR: %d", enabledCfg, loadedCnt, cfgCnt, errCnt),
    string.format("Filter: %s  Visible: %d", f, #order),
    string.format("Updated: %s", (os.date and os.date("%H:%M:%S")) or "-"),
  }
  pcall(function() txt:setText(table.concat(lines, "\n")) end)

  -- Ensure rows
  G._auditUi.rows = (type(G._auditUi.rows) == "table") and G._auditUi.rows or {}
  local rows = G._auditUi.rows

  local function createEntry()
    if not (g_ui and type(g_ui.createWidget) == "function") then return nil end
    local ok, w = pcall(function() return g_ui.createWidget("GoLAuditEntry", list) end)
    if ok and w then safeTrackWidget(w) end
    return ok and w or nil
  end

  for i, name in ipairs(order) do
    local row = rows[i]
    if not widgetAlive(row) then
      row = createEntry()
      rows[i] = row
    end
    if row then
      if type(row.setVisible) == "function" then pcall(function() row:setVisible(true) end) end

      local a = audit[name] or {}
      local nameW = getUiChild(row, "auditName")
      local stW = getUiChild(row, "auditStatus")
      local infoW = getUiChild(row, "auditInfo")
      local btnReload = getUiChild(row, "auditReload")
      local btnToggle = getUiChild(row, "auditToggle")

      if nameW and type(nameW.setText) == "function" then pcall(function() nameW:setText(tostring(name)) end) end

      local status = "OFF"
      local bg = "#333333cc"
      if snap.addonsEnabled == false then
        status = "DIS"
        bg = "#666666cc"
      else
        if a.loaded == true then
          status = "ON"
          bg = "#1f3a1fcc"
        elseif a.enabledInCfg == true then
          if a.lastError and tostring(a.lastError) ~= "" then
            status = "ERR"
            bg = "#8B0000cc"
          else
            status = "CFG"
            bg = "#4a4a4acc"
          end
        else
          status = "OFF"
          bg = "#333333cc"
        end
      end
      if stW and type(stW.setText) == "function" then pcall(function() stW:setText(status) end) end
      _auditSetBg(stW, bg)

      local info = {}
      if a.loadedAtMs then info[#info+1] = string.format("loadedAt=%dms", tonumber(a.loadedAtMs) or 0) end
      if a.initMs then info[#info+1] = string.format("init=%dms", tonumber(a.initMs) or 0) end
      if a.lastEvent and tostring(a.lastEvent) ~= "" then info[#info+1] = "last=" .. tostring(a.lastEvent) end

      local hasErr = (a.lastError and tostring(a.lastError) ~= "")
      if hasErr then
        local expanded = false
        if type(G._auditUi) == "table" and type(G._auditUi.expanded) == "table" then
          expanded = (G._auditUi.expanded[name] == true)
        end

        local errShort = _shortOneLine(a.lastError, 180)
        info[#info+1] = "ERR: " .. errShort
        _auditSetLabelColor(infoW, "#ff7777")

        if infoW then
          infoW.onClick = function()
            if type(G._auditUi) == "table" then
              G._auditUi.expanded = (type(G._auditUi.expanded) == "table") and G._auditUi.expanded or {}
              G._auditUi.expanded[name] = not (G._auditUi.expanded[name] == true)
              G._auditUi.dirty = true
            end
            pcall(updateAddonAuditUi, win, true)
          end
        end

        if infoW and type(infoW.setText) == "function" then
          local fullErr = tostring(a.lastError or ""):gsub("\r", "")
          if expanded then
            pcall(function() infoW:setText(table.concat(info, " | ") .. "\n" .. fullErr) end)
          else
            pcall(function() infoW:setText(table.concat(info, " | ")) end)
          end
        end
      else
        if a.enabledInCfg == true and a.loaded == true then
          info[#info+1] = "OK"
          _auditSetLabelColor(infoW, "#77ff77")
        else
          info[#info+1] = "-"
          _auditSetLabelColor(infoW, "#d0d0d0")
        end

        if infoW and type(infoW.setText) == "function" then
          pcall(function() infoW:setText(table.concat(info, " | ")) end)
        end
      end

      if btnReload then
        btnReload.onClick = function()
          if _G.GoLAddons and type(_G.GoLAddons.reloadOne) == "function" then
            pcall(_G.GoLAddons.reloadOne, name)
          else
            if _G.GoLAddons and type(_G.GoLAddons.disable) == "function" then pcall(_G.GoLAddons.disable, name) end
            if _G.GoLAddons and type(_G.GoLAddons.enable) == "function" then pcall(_G.GoLAddons.enable, name) end
          end
          G._auditUi.dirty = true
          scheduleDelay(function() pcall(updateAddonAuditUi, win, true) end, 120)
        end
      end

      if btnToggle then
        local wantEnable = not (a.loaded == true)
        local actionLabel = wantEnable and "Enable" or "Disable"
        if a.loaded ~= true and a.enabledInCfg == true then
          if a.lastError and tostring(a.lastError) ~= "" then
            actionLabel = "Retry"
          else
            actionLabel = "Load"
          end
        end
        if type(btnToggle.setText) == "function" then
          pcall(function() btnToggle:setText(actionLabel) end)
        end
        btnToggle.onClick = function()
          if wantEnable then
            if _G.GoLAddons and type(_G.GoLAddons.enable) == "function" then pcall(_G.GoLAddons.enable, name) end
          else
            if _G.GoLAddons and type(_G.GoLAddons.disable) == "function" then pcall(_G.GoLAddons.disable, name) end
          end
          G._auditUi.dirty = true
          scheduleDelay(function() pcall(updateAddonAuditUi, win, true) end, 120)
        end
      end
    end
  end

  -- Hide extra rows
  for i = #order + 1, #rows do
    local row = rows[i]
    if row and type(row.setVisible) == "function" then pcall(function() row:setVisible(false) end) end
  end
end

scheduleDelay = function(fn, ms)
  -- OTClient/OTCv8 compatibility wrapper:
  -- We need a local (upvalue) so UI closures created earlier can call it.
  if type(fn) ~= "function" and type(ms) == "function" then
    fn, ms = ms, fn
  end
  ms = tonumber(ms) or 0

  -- OTC/OTCv8 most common
  if scheduleEvent then
    return scheduleEvent(fn, ms)
  end

  -- Some builds expose schedule() helper
  if schedule then
    return schedule(ms, fn)
  end

  -- Dispatcher variants
  if g_dispatcher then
    if g_dispatcher.scheduleEvent then
      return g_dispatcher.scheduleEvent(fn, ms)
    end
    if g_dispatcher.addEvent then
      return g_dispatcher.addEvent(fn, ms)
    end
  end

  -- Clock variant (seen in some forks)
  if g_clock and g_clock.scheduleEvent then
    return g_clock.scheduleEvent(fn, ms)
  end

  return nil
end

local function startTelemetryLoop()
  -- One loop for UI observability. Safe on reload: guarded by LOAD_TOKEN.
  if G._telemetryEv and removeEvent then
    pcall(function() removeEvent(G._telemetryEv) end)
  end
  G._telemetryEv = nil

  local function step()
    if G._loadToken ~= LOAD_TOKEN then return end
  if (tonumber(_G.GoL_ReloadSeq) or 0) ~= LOAD_SEQ then return end
    local w = widgetAlive(G._window) and G._window or nil
    if not w then w = ensureWindow() end
    if w then
      pcall(updateDebugButton, w)
      pcall(updateTelemetryUi, w)
      pcall(updateAddonAuditUi, w)
    end

    local delay = 350
    if CFG and CFG.ui and tonumber(CFG.ui.telemetryUpdateMs) then
      delay = math.max(120, tonumber(CFG.ui.telemetryUpdateMs))
    end
    G._telemetryEv = scheduleDelay(step, delay)
  end

  -- Small initial delay so window exists.
  G._telemetryEv = scheduleDelay(step, 250)
end



local function refreshButtons()
  local win = G._window
  updateToggleButton(win, "healToggleButton", "Heal: ON", "Heal: OFF", "#00AA00cc", "#006400cc", G.flags.heal)
  updateToggleButton(win, "manaToggleButton", "Mana: ON", "Mana: OFF", "#1E90FFcc", "#00008Bcc", G.flags.mana)
  updateToggleButton(win, "lootToggleButton", "Loot: ON", "Loot: OFF", "#00AA00cc", "#8B0000cc", G.flags.loot)
  setStatusText()
  updatePauseStatus(win)
  updatePauseButton(win)
  updateQuickButtons(win)
  updateLootListUi(win)
  updateAddonButtons(win)
  updateDebugButton(win)
  updateTelemetryUi(win)
  updateAddonAuditUi(win, true)
end

G.refreshUi = refreshButtons


-- ========== BACKPACK PICKER (MAIN/LOOT/STACK) ==========
-- Uses existing bpButton0..9 in OTUI:
-- bpButton0 = MAIN selector
-- bpButton1 = LOOT selector
-- bpButton2 = STACK selector
-- bpButton3..9 = pick list (shows currently opened containers)

local BP_ROLE_BUTTON = { main = "bpButton0", loot = "bpButton1", stack = "bpButton2" }
local BP_PICK_BUTTONS = { "bpButton3", "bpButton4", "bpButton5", "bpButton6", "bpButton7", "bpButton8", "bpButton9" }

G._bpPicker = G._bpPicker or { active = nil, entries = nil }

local function cfgPathExists(path)
  if g_resources and g_resources.fileExists then
    local ok, ex = pcall(g_resources.fileExists, path)
    if ok and ex then return true end
  end
  if g_resources and g_resources.readFileContents then
    local ok, data = pcall(g_resources.readFileContents, path)
    if ok and data then return true end
  end
  if io and io.open then
    local f = io.open(path, "r")
    if f then f:close(); return true end
  end
  return false
end

local function detectConfigPath()
  local candidates = {
    "gift_of_life_config.lua",
    "gift_of_life/gift_of_life_config.lua",
    "modules/gift_of_life/gift_of_life_config.lua",
  }
  for _, p in ipairs(candidates) do
    if cfgPathExists(p) then return p end
  end
  return candidates[1]
end

local function detectStatePath()
  -- Prefer a previously chosen path (from gift_of_life_config.lua) to keep load/save consistent.
  local candidates = {
    (type(_G.GoLStatePath) == "string" and _G.GoLStatePath) or nil,
    (type(G._statePath) == "string" and G._statePath) or nil,
    "gift_of_life/gift_of_life_state.lua",
    "gift_of_life_state.lua",
    "modules/gift_of_life/gift_of_life_state.lua",
    "/gift_of_life/gift_of_life_state.lua",
    "/gift_of_life_state.lua",
    "/modules/gift_of_life/gift_of_life_state.lua",
  }

  for _, p in ipairs(candidates) do
    if type(p) == "string" and p ~= "" and cfgPathExists(p) then
      return p
    end
  end

  return "gift_of_life/gift_of_life_state.lua"
end

local function buildUiState()
  local st = {}

  -- Persist master toggles and a few UI-controlled settings.
  st.activeProfile = CFG.activeProfile

  st.healEnabled = (G.flags and G.flags.heal) and true or false
  st.manaEnabled = (G.flags and G.flags.mana) and true or false
  st.lootEnabled = (G.flags and G.flags.loot) and true or false

  if CFG and type(CFG.loot) == "table" then
    st.loot = {
      mode = CFG.loot.mode,
      itemIds = _golNormalizeIdList(CFG.loot.itemIds),
    ignoreIds = _golNormalizeIdList(CFG.loot.ignoreIds),
      mainBpNth = CFG.loot.mainBpNth,
      lootBpNth = CFG.loot.lootBpNth,
      stackBpNth = CFG.loot.stackBpNth,
      sourcePolicy = CFG.loot.sourcePolicy,
      sourceNth = CFG.loot.sourceNth,
    }
  end

  st.hudEnabled = (CFG.hudEnabled == true)

  st.ui = st.ui or {}
  st.ui.debugVisible = (G.ui and G.ui.debugVisible == true) or false
  st.ui.firstRunDone = (type(CFG.ui) == 'table' and CFG.ui.firstRunDone == true) or false



  -- Window geometry + controls (v10l): persist size/position + lock/min flags.
  do
    local win = (widgetAlive(G._window) and G._window) or ensureWindow()
    local x, y = nil, nil
    if getWinPos and win then x, y = getWinPos(win) end
    local w, h = 0, 0
    if getWinSize and win then w, h = getWinSize(win) end

    st.ui.window = (type(CFG.ui) == "table" and CFG.ui.window) or (type(st.ui.window) == "table" and st.ui.window) or {}

    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      st.ui.window.w = w
      st.ui.window.h = h
    end
    if type(x) == "number" and type(y) == "number" then
      st.ui.window.x = x
      st.ui.window.y = y
    end

    st.ui.window.locked = (G.uiLocked == true)
    st.ui.window.minimized = (G.uiMinimized == true)
  end

  -- Hotkeys mapping (optional). Default values are fork-safe strings.
  st.ui.hotkeys = (type(CFG.ui) == "table" and CFG.ui.hotkeys) or st.ui.hotkeys or {
    loot = "F6",
    heal = "F7",
    mana = "F8",
    panic = "Shift+F6",
  }

  -- Dev tools (ingame editors)
  st.dev = (type(CFG.dev) == 'table') and CFG.dev or { scripts = '', macros = '', hotkeys = '' }

  -- Addons toggles/config (kept under state so config.lua stays clean)
  st.addonsEnabled = CFG.addonsEnabled
  st.addons = CFG.addons

  -- Persist dynamically generated profiles (editable templates).
  if CFG and type(CFG.dynamicProfiles) == 'table' then
    st.dynamicProfiles = CFG.dynamicProfiles
  end


  return st
end


local function luaQuote(s)
  s = tostring(s or "")
  s = s:gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\"", "\\\"")
  return "\"" .. s .. "\""
end

local function isIdentifier(k)
  return type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil
end

local function serializeLua(v, indent)
  indent = indent or 0
  local pad = string.rep("  ", indent)
  local t = type(v)

  if t == "number" or t == "boolean" then
    return tostring(v)
  elseif t == "string" then
    return luaQuote(v)
  elseif t ~= "table" then
    return "nil"
  end

  local out = "{\n"
  -- deterministic-ish: separate array part and map part
  local maxn = 0
  for k, _ in pairs(v) do
    if type(k) == "number" and k > maxn and math.floor(k) == k then
      maxn = k
    end
  end

  for i = 1, maxn do
    out = out .. pad .. "  " .. serializeLua(v[i], indent + 1) .. ",\n"
  end

  for k, val in pairs(v) do
    local isArrayKey = type(k) == "number" and k >= 1 and k <= maxn and math.floor(k) == k
    if not isArrayKey then
      local key
      if isIdentifier(k) then
        key = k
      else
        key = "[" .. serializeLua(k, indent + 1) .. "]"
      end
      out = out .. pad .. "  " .. key .. " = " .. serializeLua(val, indent + 1) .. ",\n"
    end
  end

  out = out .. pad .. "}"
  return out
end

local function saveConfig()
  -- NOTE: we no longer overwrite gift_of_life_config.lua (it is a compatibility shim).
  -- UI changes are persisted into gift_of_life_state.lua instead.
  local path = detectStatePath()
  local header = "-- gift_of_life_state.lua\n-- Auto-generated by GiftOfLife UI. Safe to delete to reset UI overrides.\nreturn "
  local st = buildUiState()
  -- v10m: mirror window geometry into g_settings (backup persistence).
  if g_settings and st and st.ui and type(st.ui.window) == "table" then
    local w = tonumber(st.ui.window.w)
    local h = tonumber(st.ui.window.h)
    local x = tonumber(st.ui.window.x)
    local y = tonumber(st.ui.window.y)
    if w and h and w > 50 and h > 50 and type(g_settings.set) == "function" then
      pcall(function() g_settings.set(GSET_WIN_SIZE_KEY, { width = w, height = h }) end)
    end
    if x and y and x >= 0 and y >= 0 and type(g_settings.set) == "function" then
      pcall(function() g_settings.set(GSET_WIN_POS_KEY, { x = x, y = y }) end)
    end
    if type(g_settings.save) == "function" then pcall(g_settings.save) end
  end
  local body = serializeLua(st, 0) .. "\n"
  local content = header .. body

  -- Try multiple candidate paths. Some forks run dofile() with different workdirs/search paths,
  -- so the "best" writable location can vary. We also keep load/save consistent by preferring
  -- the path chosen by gift_of_life_config.lua (_G.GoLStatePath).
  local tried = {}
  local candidates = {
    (type(_G.GoLStatePath) == "string" and _G.GoLStatePath) or nil,
    (type(G._statePath) == "string" and G._statePath) or nil,
    detectStatePath(),
    "gift_of_life/gift_of_life_state.lua",
    "gift_of_life_state.lua",
    "modules/gift_of_life/gift_of_life_state.lua",
    "/gift_of_life/gift_of_life_state.lua",
    "/gift_of_life_state.lua",
    "/modules/gift_of_life/gift_of_life_state.lua",
  }

  local function ensureVfsDir(path)
    if not (g_resources and type(g_resources.makeDir) == "function") then return end
    local dir = tostring(path):match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    local accum = ""
    for part in dir:gmatch("[^/]+") do
      accum = accum .. "/" .. part
      pcall(g_resources.makeDir, accum)
      -- Some forks dislike a leading '/', so try stripped as well.
      pcall(g_resources.makeDir, accum:gsub("^/+", ""))
    end
  end

  local function vfsToAbs(path)
    if not (g_resources and type(g_resources.getRealDir) == "function") then return nil end
    local okd, realDir = pcall(g_resources.getRealDir, path)
    if not okd or type(realDir) ~= "string" or realDir == "" then return nil end

    local rp = path
    if g_resources and type(g_resources.resolvePath) == "function" then
      local okp, r = pcall(g_resources.resolvePath, path)
      if okp and type(r) == "string" and r ~= "" then rp = r end
    end

    rp = tostring(rp):gsub("^/+", "")
    realDir = tostring(realDir)
    if realDir:sub(-1) ~= "/" and realDir:sub(-1) ~= "\\" then realDir = realDir .. "/" end
    return realDir .. rp
  end

  local function tryWrite(path)
    if type(path) ~= "string" or path == "" then return false end
    if tried[path] then return false end
    tried[path] = true

    ensureVfsDir(path)

    if g_resources and g_resources.writeFileContents then
      local ok, ret = pcall(g_resources.writeFileContents, path, content)
      -- Some forks return false on failure without throwing; some return nil on success.
      if ok and ret ~= false then
        -- Verify read-back when possible.
        if g_resources.readFileContents then
          local okr, data = pcall(g_resources.readFileContents, path)
          if okr and type(data) == "string" and #data > 0 then
            G._statePath = path
            G._stateAbsPath = vfsToAbs(path) or G._stateAbsPath
            rawset(_G, "GoLStatePath", path)
            return true
          end

          -- Soft-accept: some forks write successfully but don't expose the file through readFileContents immediately.
          G._statePath = path
          G._stateAbsPath = vfsToAbs(path) or G._stateAbsPath
          rawset(_G, "GoLStatePath", path)
          return true
        else
          G._statePath = path
          G._stateAbsPath = vfsToAbs(path) or G._stateAbsPath
          rawset(_G, "GoLStatePath", path)
          return true
        end
      end
    end

    -- Absolute disk fallback: write to the real file (only if we can resolve it).
    local abs = vfsToAbs(path)
    if abs and io and io.open then
      local f = io.open(abs, "w")
      if f then
        f:write(content)
        f:close()
        G._statePath = path
        G._stateAbsPath = abs
        rawset(_G, "GoLStatePath", path)
        return true
      end
    end

    return false
  end

  for _, pth in ipairs(candidates) do
    if tryWrite(pth) then return true end
  end

  return false

end


requestSaveConfig = function()
  -- Debounced save of gift_of_life_state.lua (UI overlays). Safe across client forks.
  if not scheduleEvent then
    return saveConfig()
  end

  if removeEvent and G._saveCfgEv then pcall(removeEvent, G._saveCfgEv) end
  local ev = scheduleEvent(function()
    G._saveCfgEv = nil
    pcall(saveConfig)
  end, 350)
  G._saveCfgEv = safeTrackEvent(ev, "GoL.saveCfg")

  -- BP routing (bot foundation)
  CFG.loot.bags = (type(CFG.loot.bags) == 'table') and CFG.loot.bags or {}
  CFG.loot.bags.main = (type(CFG.loot.bags.main) == 'table') and CFG.loot.bags.main or {}
  CFG.loot.bags.stack = (type(CFG.loot.bags.stack) == 'table') and CFG.loot.bags.stack or {}
  CFG.loot.bags.nonstack = (type(CFG.loot.bags.nonstack) == 'table') and CFG.loot.bags.nonstack or {}
  if type(CFG.loot.bags.main.itemId) ~= 'number' then CFG.loot.bags.main.itemId = tonumber(CFG.loot.bags.main.itemId) or 0 end
  if type(CFG.loot.bags.stack.itemId) ~= 'number' then CFG.loot.bags.stack.itemId = tonumber(CFG.loot.bags.stack.itemId) or 0 end
  if type(CFG.loot.bags.nonstack.itemId) ~= 'number' then CFG.loot.bags.nonstack.itemId = tonumber(CFG.loot.bags.nonstack.itemId) or 0 end

  CFG.loot.itemTargets = (type(CFG.loot.itemTargets) == 'table') and CFG.loot.itemTargets or {}
  CFG.loot.sorter = (type(CFG.loot.sorter) == 'table') and CFG.loot.sorter or { enabled = false, autoSort = true }


  return true
end

-- Expose debounced saver for Dev tools
G.requestSaveConfig = requestSaveConfig




-- ========== LOOT LIST EDITOR (drag & drop) ==========
local function removeLastLootId()
  if not (CFG and CFG.loot and type(CFG.loot.itemIds) == "table") then return nil end
  if #CFG.loot.itemIds == 0 then return nil end
  return table.remove(CFG.loot.itemIds, #CFG.loot.itemIds)
end

local function clearLootIds()
  if not (CFG and CFG.loot) then return end
  CFG.loot.itemIds = {}
end


-- Loot editor UX helpers: avoid "silent no-op" feeling (duplicate drops) and keep drop target always ready.
local function _golLootDropDefaultLabelText()
  return "Loot list: drop item here to add ID"
end

local function _golGetLootDropWidgets()
  local win = widgetAlive(G._window) and G._window or ensureWindow()
  if not win then return nil, nil, nil end
  local drop = getUiChild(win, "lootDropItem")
  local preview = getUiChild(win, "lootDropPreview")
  local label = getUiChild(win, "lootEditorLabel")
  return drop, preview, label
end

local function _golFlashLootDropLabel(text, color, ms)
  local _, _, label = _golGetLootDropWidgets()
  if not label then return end

  G.ui = (type(G.ui) == "table") and G.ui or {}
  if not G.ui._lootDropLabelOrig then
    local ok, t = callAny(label, "getText")
    G.ui._lootDropLabelOrig = (ok and t and tostring(t)) or _golLootDropDefaultLabelText()
  end

  pcall(function() label:setText(tostring(text)) end)
  if color and label.setColor then
    pcall(function() label:setColor(color) end)
  end

  local tok = LOAD_TOKEN
  scheduleDelay(function()
    if G._loadToken ~= tok then return end
    local _, _, l2 = _golGetLootDropWidgets()
    if not l2 then return end
    pcall(function() l2:setText(tostring(G.ui._lootDropLabelOrig or _golLootDropDefaultLabelText())) end)
    if l2.setColor then
      pcall(function() l2:setColor("#d0d0d0") end)
    end
  end, tonumber(ms) or 1200)
end

local function _golFlashLootDropBox(bgColor, ms)
  local drop = _golGetLootDropWidgets()
  if type(drop) == "table" then drop = drop[1] end -- defensive (shouldn't happen)
  if not drop then return end

  G.ui = (type(G.ui) == "table") and G.ui or {}
  if not G.ui._lootDropBgOrig then
    -- Default from OTUI; keep if we can't read it.
    G.ui._lootDropBgOrig = "#00000022"
  end

  if drop.setBackgroundColor then
    pcall(function() drop:setBackgroundColor(bgColor) end)
    local tok = LOAD_TOKEN
    scheduleDelay(function()
      if G._loadToken ~= tok then return end
      local d2 = select(1, _golGetLootDropWidgets())
      if d2 and d2.setBackgroundColor then
        pcall(function() d2:setBackgroundColor(G.ui._lootDropBgOrig or "#00000022") end)
      end
    end, tonumber(ms) or 500)
  end
end

local function _golArmLootDropTarget()
  local drop, preview, label = _golGetLootDropWidgets()
  if drop and drop.focus then pcall(function() drop:focus() end) end
  if preview and preview.setItem then
    -- Keep preview as-is by default; but ensure it is a valid UIItem.
    pcall(function() preview:setVirtual(true) end)
  end
  if label and label.setColor then
    pcall(function() label:setColor("#d0d0d0") end)
  end
end

function _G.GiftOfLife.onLootItemDrop(self, droppedWidget, mousePos)
  if not (CFG and CFG.loot) then return false end

  local function dbg(msg)
    if CFG and CFG.debug then
      pushUiLog(msg)
    end
  end

  -- Some OTClient builds don't pass droppedWidget/mousePos to OTUI onDrop scripts.
  if not droppedWidget and g_ui then
    local ok, dw = callAny(g_ui, "getDraggingWidget")
    if ok then droppedWidget = dw end
  end

  local function extractItem(w)
    if not w then return nil end

    local ok, it = callAny(w, "getItem")
    if ok and it then return it end

    local okc, children = callAny(w, "getChildren")
    if okc and type(children) == "table" then
      for _, ch in pairs(children) do
        local it2 = extractItem(ch)
        if it2 then return it2 end
      end
    end

    return nil
  end

  local item = extractItem(droppedWidget)

  -- Extra fallback: some builds expose a "drag thing" instead of a drag widget.
  if not item and g_ui then
    local methods = { "getDraggingThing", "getDraggingItem", "getDragThing", "getDragItem" }
    for _, m in ipairs(methods) do
      local ok, it = callAny(g_ui, m)
      if ok and it then
        item = it
        break
      end
    end
  end

  if not item then
    dbg("[GoL][LootDrop] no item (drag=" .. tostring(droppedWidget) .. ")")
    return false
  end

  local ok, id = callAny(item, "getId")
  id = tonumber(id)
  if not id or id <= 0 then
    dbg("[GoL][LootDrop] bad id")
    return false
  end

  CFG.loot.itemIds = CFG.loot.itemIds or {}

  -- Update preview helper
  local function setPreview()
    local win = G._window or ensureWindow()
    local preview = win and getUiChild(win, "lootDropPreview") or nil
    if preview and preview.setItem then
      pcall(function() preview:setItem(item) end)
    end
    -- Backward compat if self is UIItem on older layouts
    if self and self.setItem then
      pcall(function() self:setItem(item) end)
    end
  end

  for _, v in ipairs(CFG.loot.itemIds) do
    if tonumber(v) == id then
      pushUiLog("Loot ID already: " .. tostring(id))
      setPreview()
      updateLootListUi(G._window or ensureWindow())
      _golFlashLootDropLabel("Already on list: " .. tostring(id), "#ffcc66", 1400)
      _golFlashLootDropBox("#664400cc", 650)
      _golArmLootDropTarget()
      return true
    end
  end


  -- Keep lists mutually exclusive (loot vs no-loot)
  if type(CFG.loot.ignoreIds) == "table" then
    for i = #CFG.loot.ignoreIds, 1, -1 do
      if tonumber(CFG.loot.ignoreIds[i]) == id then
        table.remove(CFG.loot.ignoreIds, i)
        break
      end
    end
  end

  table.insert(CFG.loot.itemIds, id)
  pushUiLog("Loot ID added: " .. tostring(id))

  setPreview()
  pcall(saveConfig)
  updateLootListUi(G._window or ensureWindow())
  _golFlashLootDropLabel("Added: " .. tostring(id), "#66ff66", 1400)
  _golFlashLootDropBox("#004400cc", 650)
  _golArmLootDropTarget()
  refreshButtons()
  return true
end


-- ========== LOOT ROUTING (BPs: MAIN/STACK/NONSTACK) ==========

local function _golResolveDroppedItemAndId(droppedWidget)
  -- Some OTClient builds don't pass droppedWidget; fallback to g_ui drag widget/thing.
  if not droppedWidget and g_ui then
    local ok, dw = callAny(g_ui, "getDraggingWidget")
    if ok then droppedWidget = dw end
  end

  local function extractItem(w)
    if not w then return nil end
    local ok, it = callAny(w, "getItem")
    if ok and it then return it end
    local okc, children = callAny(w, "getChildren")
    if okc and type(children) == "table" then
      for _, ch in pairs(children) do
        local it2 = extractItem(ch)
        if it2 then return it2 end
      end
    end
    return nil
  end

  local item = extractItem(droppedWidget)

  if not item and g_ui then
    local methods = { "getDraggingThing", "getDraggingItem", "getDragThing", "getDragItem" }
    for _, m in ipairs(methods) do
      local ok, it = callAny(g_ui, m)
      if ok and it then
        item = it
        break
      end
    end
  end

  if not item then return nil, nil end
  local ok, id = callAny(item, "getId")
  id = tonumber(id)
  if not id or id <= 0 then return item, nil end
  return item, id
end

local function _golItemIsContainer(item)
  if not item then return false end
  local methods = { "isContainer", "isContainerItem", "isBackpack" }
  for _, m in ipairs(methods) do
    local ok, v = callAny(item, m)
    if ok and type(v) == "boolean" then return v end
  end
  return false
end

local function _golSetUIItemId(uiItem, itemId)
  if not uiItem then return end
  itemId = tonumber(itemId) or 0
  local methods = { "setItemId", "setItemID" }
  for _, m in ipairs(methods) do
    if type(uiItem[m]) == "function" then
      pcall(function() uiItem[m](uiItem, itemId) end)
      return
    end
  end
  -- last resort: clear by setVirtual
  pcall(function() uiItem:setVirtual(true) end)
end

function _G.GiftOfLife.updateLootBagConfigUi(win)
  if not win then win = G._window end
  if not win or not CFG or not CFG.loot then return end
  _golEnsureLootLists()

  local function apply(kind, iconId, textId)
    local icon = getUiChild(win, iconId)
    local text = getUiChild(win, textId)
    local bag = CFG.loot.bags and CFG.loot.bags[kind]
    local id = bag and tonumber(bag.itemId) or 0
    if icon then _golSetUIItemId(icon, id) end
    if text and type(text.setText) == "function" then
      local t = (id and id > 0) and ("id: " .. tostring(id)) or "(unset)"
      pcall(function() text:setText(t) end)
    end
  end

  apply("main", "lootBagMainIcon", "lootBagMainText")
  apply("stack", "lootBagStackIcon", "lootBagStackText")
  apply("nonstack", "lootBagNonStackIcon", "lootBagNonStackText")
end

function _G.GiftOfLife.setLootBag(kind, itemId)
  if not _golEnsureLootLists() then return false end
  kind = tostring(kind or "")
  if kind ~= "main" and kind ~= "stack" and kind ~= "nonstack" then return false end
  itemId = tonumber(itemId) or 0
  CFG.loot.bags[kind].itemId = itemId
  pcall(saveConfig)
  GiftOfLife.updateLootBagConfigUi(G._window)
  pushUiLog("[Loot] BP " .. kind .. " = " .. tostring(itemId))
  return true
end

function _G.GiftOfLife.setLootTarget(itemId, kind)
  if not _golEnsureLootLists() then return false end
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end
  kind = tostring(kind or "")
  if kind ~= "main" and kind ~= "stack" and kind ~= "nonstack" then return false end
  CFG.loot.itemTargets[tostring(id)] = kind
  pcall(saveConfig)
  return true
end

function _G.GiftOfLife.onIgnoreItemDrop(self, droppedWidget, mousePos)
  local item, id = _golResolveDroppedItemAndId(droppedWidget)
  if not id then
    _golFlashLootDropLabel("Drop an item to IGNORE", "#ff7777", 700)
    return false
  end
  GiftOfLife.addNoLootId(id, false)
  _golFlashLootDropLabel("Ignored: " .. tostring(id), "#ff7777", 650)
  return true
end

function _G.GiftOfLife.onLootRouteDrop(kind, self, droppedWidget, mousePos)
  if not _golEnsureLootLists() then return false end
  local item, id = _golResolveDroppedItemAndId(droppedWidget)
  if not id then
    pushUiLog("[Loot] drop: no item id")
    return false
  end

  -- Backpack drop => configure routing BP for this kind.
  if _golItemIsContainer(item) then
    return GiftOfLife.setLootBag(kind, id)
  end

  -- Normal item drop => add to LOOT and route to this BP kind.
  GiftOfLife.addLootId(id, true)
  GiftOfLife.setLootTarget(id, kind)
  _golFlashLootDropLabel("Loot+Route (" .. kind .. "): " .. tostring(id), "#77ff77", 650)
  updateLootListUi(G._window)
  return true
end



-- ========== CONTEXT MENU (Add loot / no-loot) ==========
-- Adds two options to the default right-click item menu:
--   - Add loot
--   - Ignore
--
-- IMPORTANT:
-- The Althea/OTClient build we target implements:
--   modules.game_interface.addMenuHook(category, text, callback, condition)
-- and createThingMenu() calls option.condition() without nil-guard.
-- So we MUST provide a condition function for every hook option.
--
-- This block also includes a cleanup routine for an older broken hook call
-- (where addMenuHook() was called with only 2 args, producing an option with
-- nil callback/condition and crashing createThingMenu).

local function _golIdInList(list, id)
  if type(list) ~= 'table' then return false end
  local nid = tonumber(id)
  if not nid then return false end
  for _, v in ipairs(list) do
    if tonumber(v) == nid then return true end
  end
  return false
end

local function _golRemoveIdFromList(list, id)
  if type(list) ~= 'table' then return false end
  local nid = tonumber(id)
  if not nid then return false end
  for i = #list, 1, -1 do
    if tonumber(list[i]) == nid then
      table.remove(list, i)
      return true
    end
  end
  return false
end

local function _golEnsureLootLists()
  if not CFG then return false end
  CFG.loot = CFG.loot or {}
  CFG.loot.itemIds = (type(CFG.loot.itemIds) == 'table') and CFG.loot.itemIds or {}
  CFG.loot.ignoreIds = (type(CFG.loot.ignoreIds) == 'table') and CFG.loot.ignoreIds or {}  -- Normalize tables to array-style so UI (#list) works reliably.
  CFG.loot.itemIds = _golNormalizeIdList(CFG.loot.itemIds)
  CFG.loot.ignoreIds = _golNormalizeIdList(CFG.loot.ignoreIds)


  return true
end

function _G.GiftOfLife.addLootId(itemId, silent)
  if not _golEnsureLootLists() then return false end
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end

  -- If it was on ignore list, remove it.
  _golRemoveIdFromList(CFG.loot.ignoreIds, id)

  if _golIdInList(CFG.loot.itemIds, id) then
    if not silent then pushUiLog('Loot already has: ' .. tostring(id)) end
    return false
  end

  table.insert(CFG.loot.itemIds, id)
  if not silent then pushUiLog('Loot ID added: ' .. tostring(id)) end
  -- Persist state (loot lists live in gift_of_life_state.lua overlay).
local savedOk = false
if requestSaveConfig then
  savedOk = pcall(requestSaveConfig)
else
  local ok, ret = pcall(saveConfig)
  savedOk = ok and (ret ~= false)
end
if not savedOk then
  pcall(function() pushUiLog("WARN: state save failed") end)
end

-- Update UI list immediately (context menu may fire outside normal UI click flow).
local w = (widgetAlive(G._window) and G._window) or ensureWindow()
if w then pcall(updateLootListUi, w) end

pcall(refreshButtons)
return true
end

function _G.GiftOfLife.addNoLootId(itemId, silent)
  if not _golEnsureLootLists() then return false end
  local id = tonumber(itemId)
  if not id or id <= 0 then return false end

  -- If it was on loot list, remove it.
  _golRemoveIdFromList(CFG.loot.itemIds, id)

  if _golIdInList(CFG.loot.ignoreIds, id) then
    if not silent then pushUiLog('NoLoot already has: ' .. tostring(id)) end
    return false
  end

  table.insert(CFG.loot.ignoreIds, id)
  if not silent then pushUiLog('NoLoot ID added: ' .. tostring(id)) end
  -- Persist state (loot lists live in gift_of_life_state.lua overlay).
local savedOk = false
if requestSaveConfig then
  savedOk = pcall(requestSaveConfig)
else
  local ok, ret = pcall(saveConfig)
  savedOk = ok and (ret ~= false)
end
if not savedOk then
  pcall(function() pushUiLog("WARN: state save failed") end)
end

-- Update UI list immediately (context menu may fire outside normal UI click flow).
local w = (widgetAlive(G._window) and G._window) or ensureWindow()
if w then pcall(updateLootListUi, w) end

pcall(refreshButtons)
return true
end

local function _golTypeName(obj)
  if obj == nil then return 'nil' end
  if tolua and type(tolua.type) == 'function' then
    local ok, t = pcall(tolua.type, obj)
    if ok and type(t) == 'string' then return t end
  end
  if type(obj) == 'table' and type(obj.getClassName) == 'function' then
    local ok, t = pcall(obj.getClassName, obj)
    if ok and type(t) == 'string' then return t end
  end
  return type(obj)
end

local function _golExtractItemFromArgs(...)
  -- OTClient builds differ: sometimes createThingMenu passes an Item, sometimes a Thing,
  -- and sometimes the UIItem widget itself. So we detect by capabilities, not by typename.
  for i = 1, select('#', ...) do
    local v = select(i, ...)
    if v ~= nil then
      -- UIItem (or similar) often exposes getItem()
      local okGetItem, it = callAny(v, 'getItem')
      if okGetItem and it ~= nil then
        local okId, id = callAny(it, 'getId')
        id = tonumber(id)
        if okId and id and id > 0 then
          return it
        end
      end

      -- Direct Thing/Item: accept anything with a sane getId(), but try to avoid creatures.
      local okId, id = callAny(v, 'getId')
      id = tonumber(id)
      if okId and id and id > 0 then
        local okIsCreature, isCreature = callAny(v, 'isCreature')
        if okIsCreature and isCreature then
          -- skip creatures
        else
          local okIsItem, isItem = callAny(v, 'isItem')
          if okIsItem then
            if isItem then return v end
          else
            -- Many builds don't expose isItem() on Item, so as a fallback we accept it.
            return v
          end
        end
      end
    end
  end
  return nil
end

local function _golCtxCondition(...)
  if G._loadToken ~= LOAD_TOKEN then return false end
  local item = _golExtractItemFromArgs(...)
  if not item then return false end
  local ok, id = callAny(item, 'getId')
  id = tonumber(id)
  return (ok and id and id > 0) and true or false
end

local function _golCtxAddLoot(...)
  if G._loadToken ~= LOAD_TOKEN then return end
  if (tonumber(_G.GoL_ReloadSeq) or 0) ~= LOAD_SEQ then return end
  local item = _golExtractItemFromArgs(...)
  if not item then return end
  local ok, id = callAny(item, 'getId')
  id = tonumber(id)
  if not ok or not id or id <= 0 then return end
  _G.GiftOfLife.addLootId(id)
end

local function _golCtxAddNoLoot(...)
  if G._loadToken ~= LOAD_TOKEN then return end
  if (tonumber(_G.GoL_ReloadSeq) or 0) ~= LOAD_SEQ then return end
  local item = _golExtractItemFromArgs(...)
  if not item then return end
  local ok, id = callAny(item, 'getId')
  id = tonumber(id)
  if not ok or not id or id <= 0 then return end
  _G.GiftOfLife.addNoLootId(id)
end

local function _golCleanupHookedMenuOptions(gi, cat)
  if not gi or type(gi.hookedMenuOptions) ~= 'table' then return end
  local t = gi.hookedMenuOptions[cat]
  if type(t) ~= 'table' then return end

  for i = #t, 1, -1 do
    local opt = t[i]
    if type(opt) == 'table' then
      -- Older broken install: addMenuHook(cat, function) -> text=function, callback=nil, condition=nil
      if type(opt.text) == 'function' and opt.callback == nil and opt.condition == nil then
        table.remove(t, i)
      end
      -- Ultra defensive: if some option is missing condition, remove it instead of crashing createThingMenu.
      if opt.condition == nil then
        if opt.text == 'Add loot' or opt.text == 'Ignore' or type(opt.text) == 'function' then
          table.remove(t, i)
        end
      end
    end
  end
end

local function _golRemoveOurMenuOptions(gi, cat)
  if not gi then return end
  if type(gi.hookedMenuOptions) == 'table' then
    local t = gi.hookedMenuOptions[cat]
    if type(t) == 'table' then
      for i = #t, 1, -1 do
        local opt = t[i]
        if type(opt) == 'table' then
          if (opt.text == 'Add loot' and opt.callback == G._ctxMenuCbLoot) or
             (opt.text == 'Ignore' and opt.callback == G._ctxMenuCbNoLoot) then
            table.remove(t, i)
          end
        end
      end
    end
  end

  if type(gi.removeMenuHook) == 'function' then
    -- Try common signatures (best effort)
    pcall(gi.removeMenuHook, cat, 'Add loot')
    pcall(gi.removeMenuHook, cat, 'Add loot', G._ctxMenuCbLoot)
    pcall(gi.removeMenuHook, cat, 'Ignore')
    pcall(gi.removeMenuHook, cat, 'Ignore', G._ctxMenuCbNoLoot)
    pcall(gi.removeMenuHook, cat, G._ctxMenuCbLoot)
    pcall(gi.removeMenuHook, cat, G._ctxMenuCbNoLoot)
  end
end

local function installLootContextMenuHook()
  if G._ctxMenuInstalled then return end
  if not modules or not modules.game_interface then return end
  local gi = modules.game_interface
  if type(gi.addMenuHook) ~= 'function' then return end

  -- store callbacks (so we can remove exactly ours on reload)
  G._ctxMenuCbLoot = _golCtxAddLoot
  G._ctxMenuCbNoLoot = _golCtxAddNoLoot
  G._ctxMenuCond = _golCtxCondition

  local function tryInstall(cat)
    _golCleanupHookedMenuOptions(gi, cat)
    _golRemoveOurMenuOptions(gi, cat)

    local ok1 = pcall(gi.addMenuHook, cat, 'Add loot', G._ctxMenuCbLoot, G._ctxMenuCond)
    local ok2 = pcall(gi.addMenuHook, cat, 'Ignore', G._ctxMenuCbNoLoot, G._ctxMenuCond)
    return ok1 and ok2
  end

  local installed = false

  if _G.ThingCategoryItem ~= nil then
    installed = tryInstall(_G.ThingCategoryItem)
    if installed then G._ctxMenuCategory = _G.ThingCategoryItem end
  end

  if not installed then
    installed = tryInstall('item')
    if installed then G._ctxMenuCategory = 'item' end
  end

  if installed then
    G._ctxMenuInstalled = true
  end
  pcall(function() pushUiLog('Context menu hook: ON') end)
end

local function uninstallLootContextMenuHook()
  if not modules or not modules.game_interface then return end
  local gi = modules.game_interface

  local cat = G._ctxMenuCategory
  if cat == nil then
    if _G.ThingCategoryItem ~= nil then cat = _G.ThingCategoryItem else cat = 'item' end
  end

  _golCleanupHookedMenuOptions(gi, cat)
  _golRemoveOurMenuOptions(gi, cat)

  G._ctxMenuInstalled = false
  G._ctxMenuCategory = nil
  G._ctxMenuCbLoot = nil
  G._ctxMenuCbNoLoot = nil
  G._ctxMenuCond = nil
end


local function getContainersOrdered()
  local list = {}
  if not g_game or not g_game.getContainers then return list end

  local ok, conts = pcall(g_game.getContainers, g_game)
  if (not ok) or type(conts) ~= "table" then
    ok, conts = pcall(g_game.getContainers)
  end
  if type(conts) ~= "table" then return list end

  for id, c in pairs(conts) do
    if c then table.insert(list, { id = id, c = c }) end
  end

  table.sort(list, function(a, b)
    local ai = tonumber(a.id) or 0
    local bi = tonumber(b.id) or 0
    if ai == bi then
      return tostring(a.id) < tostring(b.id)
    end
    return ai < bi
  end)

  return list
end

local function containerDisplayName(c, id)
  if not c then return "Container " .. tostring(id) end

  local getters = { "getName", "getTitle", "getCaption" }
  for _, fn in ipairs(getters) do
    local f = c[fn]
    if type(f) == "function" then
      local ok, v = pcall(f, c)
      if ok and type(v) == "string" and v ~= "" then
        return v
      end
    end
  end

  return "Container " .. tostring(id)
end

local function setChildText(win, id, text)
  if not win then return end
  local ok, w = callAny(win, "getChildById", id)
  if not ok or not w then ok, w = callAny(win, "recursiveGetChildById", id) end
  if not w then return end
  pcall(function() w:setText(text) end)
end

local function setChildBg(win, id, color)
  if not win then return end
  local ok, w = callAny(win, "getChildById", id)
  if not ok or not w then ok, w = callAny(win, "recursiveGetChildById", id) end
  if not w then return end
  pcall(function() w:setBackgroundColor(color) end)
end

local function clearPickList(win)
  for _, id in ipairs(BP_PICK_BUTTONS) do
    local ok, b = callAny(win, "getChildById", id)
    if not ok or not b then ok, b = callAny(win, "recursiveGetChildById", id) end
    if b then
      b.onClick = nil
      pcall(function() b:setText("...") end)
      pcall(function() b:setBackgroundColor("#222222cc") end)
      -- Hide pick buttons unless picker is active (prevents "..." spam and frees space).
      pcall(function() b:setVisible(false) end)
    end
  end
end

local function updateBpRoleButtons()
  local win = G._window
  if not win or not (CFG and CFG.loot) then return end

  local entries = getContainersOrdered()

  local function roleText(kindUpper, nth)
    nth = tonumber(nth) or 1
    local e = entries[nth]
    if e then
      local name = containerDisplayName(e.c, e.id)
      local capOk, cap = callAny(e.c, "getCapacity")
      local cntOk, cnt = callAny(e.c, "getItemsCount")
      if capOk and cntOk and type(cap) == "number" and type(cnt) == "number" and cap > 0 then
        return string.format("%s BP: %d) %s [%d/%d]", kindUpper, nth, name, cnt, cap)
      end
      return string.format("%s BP: %d) %s", kindUpper, nth, name)
    end
    return string.format("%s BP: %d", kindUpper, nth)
  end

  setChildText(win, BP_ROLE_BUTTON.main,  roleText("MAIN",  CFG.loot.mainBpNth))
  setChildText(win, BP_ROLE_BUTTON.loot,  roleText("LOOT",  CFG.loot.lootBpNth))
  setChildText(win, BP_ROLE_BUTTON.stack, roleText("STACK", CFG.loot.stackBpNth))

  setChildText(win, "backpackLabel", "Backpacks (click MAIN/LOOT/STACK to assign)")
  clearPickList(win)
end

local function openBpPicker(kind)
  local win = G._window
  if not win or not (CFG and CFG.loot) then return end

  local entries = getContainersOrdered()
  G._bpPicker.active = kind
  G._bpPicker.entries = entries

  -- highlight active role button
  setChildBg(win, BP_ROLE_BUTTON.main,  "#222222cc")
  setChildBg(win, BP_ROLE_BUTTON.loot,  "#222222cc")
  setChildBg(win, BP_ROLE_BUTTON.stack, "#222222cc")
  setChildBg(win, BP_ROLE_BUTTON[kind], "#AAAA00cc")

  setChildText(win, "backpackLabel", string.format("Pick %s BP (choose from opened containers below)", string.upper(kind)))

  -- show first 7 opened containers as choices (hide unused slots)
  for i, btnId in ipairs(BP_PICK_BUTTONS) do
    local ok, b = callAny(win, "getChildById", btnId)
    if not ok or not b then ok, b = callAny(win, "recursiveGetChildById", btnId) end
    if b then
      local e = entries[i]
      if e then
        local name = containerDisplayName(e.c, e.id)
        local txt = string.format("%d) %s", i, name)
        pcall(function() b:setText(txt) end)
        pcall(function() b:setBackgroundColor("#333333cc") end)
        pcall(function() b:setVisible(true) end)

        b.onClick = function()
          if kind == "main" then
            CFG.loot.mainBpNth = i
          elseif kind == "loot" then
            CFG.loot.lootBpNth = i
          elseif kind == "stack" then
            CFG.loot.stackBpNth = i
          end

          local saved = saveConfig()
          if not saved then print('[GiftOfLife] WARNING: cannot write config file (BP selection not persisted).') end
          G._bpPicker.active = nil

          -- restore role highlight
          setChildBg(win, BP_ROLE_BUTTON.main,  "#222222cc")
          setChildBg(win, BP_ROLE_BUTTON.loot,  "#222222cc")
          setChildBg(win, BP_ROLE_BUTTON.stack, "#222222cc")

          updateBpRoleButtons()
        end
      else
        b.onClick = nil
        pcall(function() b:setText("...") end)
        pcall(function() b:setBackgroundColor("#222222cc") end)
        pcall(function() b:setVisible(false) end)
      end
    end
  end
end



ensureWindow = function()
  if widgetAlive(G._window) then return G._window end

  local rootPanel = nil
  if modules and modules.game_interface and modules.game_interface.getRootPanel then
    local ok, r = pcall(modules.game_interface.getRootPanel)
    if ok then rootPanel = r end
  end
  local rootWidget = (g_ui and g_ui.getRootWidget) and g_ui.getRootWidget() or nil

  local function findExistingIn(root)
    if not widgetAlive(root) then return nil end
    if type(root.recursiveGetChildById) ~= 'function' then return nil end
    local ok, w = pcall(function() return root:recursiveGetChildById('giftOfLifeWindow') end)
    if ok and w and widgetAlive(w) then return w end
    return nil
  end

  -- Prefer rootPanel but avoid double-load when rootPanel appears after early log writes.
  local existing = findExistingIn(rootPanel) or findExistingIn(rootWidget)
  if existing then
    G._window = existing
    local te = getUiChild(existing, 'actionLogText')
    local sb = getUiChild(existing, 'actionLogScroll')
    if te and sb and te.setVerticalScrollBar then
      pcall(function() te:setVerticalScrollBar(sb) end)
    end
    return existing
  end

  local root = rootPanel or rootWidget

  if G._uiSuppressed == true then return nil end

  if not widgetAlive(root) then return nil end

  -- Defensive: kill stale instances in BOTH roots (prevents orphan windows with auto ids).
  local function destroyIfFound(r)
    if not widgetAlive(r) or type(r.recursiveGetChildById) ~= 'function' then return end
    local okOld, old = pcall(function() return r:recursiveGetChildById('giftOfLifeWindow') end)
    if okOld and old and widgetAlive(old) and type(old.destroy) == 'function' then
      pcall(old.destroy, old)
    end
  end
  destroyIfFound(rootPanel)
  if rootWidget ~= rootPanel then destroyIfFound(rootWidget) end

  if not (g_ui and g_ui.loadUI) then return nil end

  -- Ensure module search paths exist when running via dofile().
  if g_resources and type(g_resources.getWorkDir) == 'function' and type(g_resources.addSearchPath) == 'function' then
    local wd = g_resources.getWorkDir()
    pcall(function() g_resources.addSearchPath(wd .. 'modules', true) end)
    pcall(function() g_resources.addSearchPath(wd .. 'modules/gift_of_life', true) end)
  end

  local win = nil

  local function tryLoadUI(path)
    local ok2, w = pcall(function() return g_ui.loadUI(path, root) end)
    if ok2 and w and widgetAlive(w) then
      win = w
      G._window = win
      pcall(function() win:setText('Gift of Life v12 PRO (PRE9)') end)
      print(string.format('[GiftOfLife] UI loaded: %s', path))
      return true
    end
    if not ok2 then
      print(string.format('[GiftOfLife] UI load failed: %s (%s)', path, tostring(w)))
    end
    return false
  end

  -- Prefer unique UI to avoid collisions with older installs.
  local uiCandidates = {
    'gift_of_life_v10l.otui',
    '/modules/gift_of_life/gift_of_life_v10l.otui',
    '/gift_of_life/gift_of_life_v10l.otui',
    'gift_of_life.otui',
    '/modules/gift_of_life/gift_of_life.otui',
    '/gift_of_life/gift_of_life.otui',
    'gift_of_life_v10l_fallback.otui',
    'gift_of_life_fallback.otui',
  }

  for _, p in ipairs(uiCandidates) do
    if tryLoadUI(p) then break end
  end

  if not win then
    print('[GiftOfLife] UI load FAILED (no candidate worked)')
    return nil
  end

  -- Manual wire scrollbar.
  local te = getUiChild(win, 'actionLogText')
  local sb = getUiChild(win, 'actionLogScroll')
  if te and sb and te.setVerticalScrollBar then
    pcall(function() te:setVerticalScrollBar(sb) end)
  end

  G._window = win
  safeTrackWidget(win)

  -- Profiles: update label + show first-run profile picker.
  pcall(function() updateProfileLabel(win) end)
  pcall(function() showProfilePickerIfFirstRun() end)

  return win
end


local function bindButtons()
  local win = ensureWindow()
  if not win then return end
  pcall(_syncUiLog)
G._rebindUi = bindButtons


  applyWindowChrome(win)


  -- v11E: tooltips (UI-only quality)
  local function tip(id, text)
    local w = getUiChild(win, id)
    if w then safeSetTooltip(w, text) end
    return w
  end

  tip("rotationEditButton", "Open spell rotation editor (per-profile).")
  tip("hotkeysToggleButton", "Collapse/expand hotkeys section (saved in state).")
  tip("hkApplyButton", "Apply hotkeys (bind keys now).")
  tip("hkResetButton", "Reset hotkeys to defaults.")
  tip("lootDropItem", "Drop an item here to add its ID to loot list.")
  tip("compactToggleButton", "Toggle compact UI (saved in state).")
  tip("narrowToggleButton", "Toggle narrow width (saved in state).")
  tip("tabMain", "Main view")
    tip("tabLoot", "Loot + BP")
  tip("tabSpellRune", "Spells/Runes + DBG/DEV")
        tip("addonsToggleButton", "Collapse/expand addons card")
  tip("bpToggleButton", "Collapse/expand backpacks card")
  tip("telemetryToggleButton", "Collapse/expand telemetry card")
  tip("addonAuditRefreshButton", "Refresh Addon Audit Harness view.")
  tip("addonAuditReloadAllButton", "Soft reload enabled addons (no UI purge).")
  tip("addonAuditCopyButton", "Print audit report to console.")
  tip("addonAuditFilterButton", "Cycle filter: ALL/ERR/CFG/ON/OFF/DIS.")
  tip("devReloadButton", "Compile/run Dev scripts/macros/hotkeys from saved editor text.")
  tip("devOpenScriptsButton", "Open ingame script editor (saved in state).")
  tip("devOpenMacrosButton", "Open ingame macro editor (saved in state).")
  tip("devOpenHotkeysButton", "Open ingame hotkey editor (saved in state).")
  tip("devOpenCatalogButton", "Show available helpers and examples.")

  -- Rotation editor (spells)
  local rotationEditButton = getUiChild(win, "rotationEditButton")
  if rotationEditButton then
    rotationEditButton.onClick = function()
      openRotationEditor()
    end
  end


  
  -- v11C: collapsible Hotkeys panel (persisted)
  do
    local tbtn = getUiChild(win, "hotkeysToggleButton")
    local body = getUiChild(win, "hotkeysBody")
    if tbtn and body then
      local function applyHotkeysCollapse()
        local collapsed = (CFG and type(CFG.ui) == "table" and CFG.ui.hotkeysCollapsed == true)
        pcall(function() body:setVisible(not collapsed) end)
        pcall(function() tbtn:setText(collapsed and "Show hotkeys" or "Hide hotkeys") end)
      end

      applyHotkeysCollapse()

      tbtn.onClick = function()
        CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
        CFG.ui.hotkeysCollapsed = not (CFG.ui.hotkeysCollapsed == true)
        if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end
        applyHotkeysCollapse()
      end
    end
  end


  -- v11G: Collapsible cards (persisted)
  do
    local function bindCollapse(btnId, bodyId, key, showText, hideText)
      local btn = getUiChild(win, btnId)
      local body = getUiChild(win, bodyId)
      if not (btn and body) then return end

      local function apply()
        CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
        CFG.ui.cards = (type(CFG.ui.cards) == "table") and CFG.ui.cards or {}
        local collapsed = (CFG.ui.cards[key] == true)
        pcall(function() body:setVisible(not collapsed) end)
        if type(btn.setText) == "function" then
          pcall(function() btn:setText(collapsed and showText or hideText) end)
        end
      end

      apply()

      btn.onClick = function()
        CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
        CFG.ui.cards = (type(CFG.ui.cards) == "table") and CFG.ui.cards or {}
        CFG.ui.cards[key] = not (CFG.ui.cards[key] == true)
        if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end
        apply()
      end
    end

    bindCollapse("addonsToggleButton", "addonsBody", "addons", "Show addons", "Hide addons")
    bindCollapse("bpToggleButton", "bpBody", "backpacks", "Show backpacks", "Hide backpacks")
    bindCollapse("telemetryToggleButton", "telemetryBody", "telemetry", "Show telemetry", "Hide telemetry")
  end

  -- v11H: Addon Audit Harness (AAH) buttons
do
  local function markDirty()
    if type(G._auditUi) == "table" then G._auditUi.dirty = true end
  end

  local rbtn = getUiChild(win, "addonAuditRefreshButton")
  if rbtn then
    rbtn.onClick = function()
      markDirty()
      pcall(updateAddonAuditUi, win, true)
    end
  end


  local fbtn = getUiChild(win, "addonAuditFilterButton")
  if fbtn then
    fbtn.onClick = function()
      local seq = { "ALL", "ERR", "CFG", "ON", "OFF", "DIS" }
      local cur = "ALL"
      if type(G._auditUi) == "table" then cur = tostring(G._auditUi.filter or "ALL") end
      local idx = 1
      for i, v in ipairs(seq) do if v == cur then idx = i break end end
      local nxt = seq[(idx % #seq) + 1]
      if type(G._auditUi) == "table" then
        G._auditUi.filter = nxt
        G._auditUi.dirty = true
      end
      pcall(updateAddonAuditUi, win, true)
    end
  end

  local cbtn = getUiChild(win, "addonAuditCopyButton")
  if cbtn then
    cbtn.onClick = function()
      local snap = _auditSnapshot()
      local order0 = (type(snap.order) == "table") and snap.order or {}
      local audit = (type(snap.audit) == "table") and snap.audit or {}
      local order = _auditSortedFilteredOrder(snap, order0, audit)
      safePrint(string.format("[GoL][AAH] AddonsEnabled=%s", (snap.addonsEnabled == false) and "NO" or "YES"))
      for _, name in ipairs(order) do
        local a = audit[name] or {}
        local status = "OFF"
        if snap.addonsEnabled == false then
          status = "DIS"
        else
          if a.loaded == true then
            status = "ON"
          elseif a.enabledInCfg == true then
            if a.lastError and tostring(a.lastError) ~= "" then
              status = "ERR"
            else
              status = "CFG"
            end
          else
            status = "OFF"
          end
        end
        local err = (a.lastError and tostring(a.lastError) ~= "") and _shortOneLine(a.lastError, 120) or ""
        safePrint(string.format("[GoL][AAH] %s: %s%s", tostring(name), status, (err ~= "" and (" | " .. err) or "")))
      end
    end
  end

  local allbtn = getUiChild(win, "addonAuditReloadAllButton")
  if allbtn then
    allbtn.onClick = function()
      if _G.GoLAddons and type(_G.GoLAddons.reloadEnabled) == "function" then
        pcall(_G.GoLAddons.reloadEnabled, { purge = false })
      else
        local snap = _auditSnapshot()
        local order = (type(snap.order) == "table") and snap.order or {}
        local audit = (type(snap.audit) == "table") and snap.audit or {}
        for _, name in ipairs(order) do
          local a = audit[name] or {}
          if a.enabledInCfg == true then
            if _G.GoLAddons and type(_G.GoLAddons.reloadOne) == "function" then
              pcall(_G.GoLAddons.reloadOne, name)
            else
              if _G.GoLAddons and type(_G.GoLAddons.disable) == "function" then pcall(_G.GoLAddons.disable, name) end
              if _G.GoLAddons and type(_G.GoLAddons.enable) == "function" then pcall(_G.GoLAddons.enable, name) end
            end
          end
        end
      end
      markDirty()
      scheduleDelay(function() pcall(updateAddonAuditUi, win, true) end, 180)
    end
  end
end


-- v12: Dev Tools buttons (Dbg-only)
do
  local function hasDev()
    return _G.GoLDev and type(_G.GoLDev.openEditor) == "function"
  end

  local function bindBtn(id, fn)
    local b = getUiChild(win, id)
    if b then
      b.onClick = fn
    end
  end

  bindBtn("devReloadButton", function()
    if hasDev() and type(_G.GoLDev.reloadFromState) == "function" then
      _G.GoLDev.reloadFromState()
    else
      safePrint("[GoL][Dev] module not loaded")
    end
  end)

  bindBtn("devOpenScriptsButton", function()
    if hasDev() then _G.GoLDev.openEditor("scripts") end
  end)

  bindBtn("devOpenMacrosButton", function()
    if hasDev() then _G.GoLDev.openEditor("macros") end
  end)

  bindBtn("devOpenHotkeysButton", function()
    if hasDev() then _G.GoLDev.openEditor("hotkeys") end
  end)

  bindBtn("devOpenCatalogButton", function()
    if _G.GoLDev and type(_G.GoLDev.openCatalog) == "function" then _G.GoLDev.openCatalog() end
  end)

  -- Hand main window to dev module so it can update devStatusLabel.
  if _G.GoLDev and type(_G.GoLDev.bindMainWindow) == "function" then
    pcall(_G.GoLDev.bindMainWindow, win)
  end
end

-- v10l PRO: Hotkey editor panel (Apply/Reset + live rebind + state)
  local function hkDefaults()
    return { loot = "F6", heal = "F7", mana = "F8", panic = "Shift+F6" }
  end

  local function hkNormalize(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%s*%+%s*", "+")
    return s
  end


  -- v11F: Tabs + Compact mode (UI-only)
  if type(CFG.ui) ~= "table" then CFG.ui = {} end
  if type(CFG.ui.activeTab) ~= "string" or CFG.ui.activeTab == "" then CFG.ui.activeTab = "main" end
  if type(CFG.ui.compactMode) ~= "boolean" then CFG.ui.compactMode = false end

  local function _golSetBtnOn(btn, on)
    if not btn then return end
    if type(btn.setOn) == "function" then
      pcall(function() btn:setOn(on) end)
    elseif type(btn.setChecked) == "function" then
      pcall(function() btn:setChecked(on) end)
    end
  end

  local function _golSetVisible(id, v)
    local w = getUiChild(win, id)
    if w and type(w.setVisible) == "function" then pcall(function() w:setVisible(v) end) end
  end

  local _golHeaderAlways = {
    "statusPanel",
    "actionLogPanel",
    "quickSettingsRow",
    "compactToggleButton",
    "narrowToggleButton",
    "tabBarPanel",
    "pauseStatusLabel",
  }

  local _golAllSections = {
    -- common (non-header)
    "debugToggleButton",
    "pauseToggleButton",
    "rotationEditButton",
    "togglesPanel",

    -- content groups
    "profileLabel",
    "profileChangeButton",

    "lootEditorLabel",
    "lootBagConfigPanel",
    "lootEditorRow",
    "lootListLabelPanel",
    "backpackLabel",
    "bpPickerPanel",

    "addonsLabel",
    "addonsPanel",

    "telemetryPanel",
    "addonAuditPanel",
    "devToolsPanel",
  }

  local _golTabGroups = {
    -- MAIN: czysty ekran + profil
    main = {
      "profileLabel",
      "profileChangeButton",
    },

    -- LOOT: loot + BP razem
    loot = {
      "lootEditorLabel",
      "lootBagConfigPanel",
      "lootEditorRow",
      "lootListLabelPanel",
    },

    -- SPELL_RUNE: rotacje/spelle + DBG + DEV (+ addons/toggles na razie)
    spell_rune = {
      "rotationEditButton",
      "togglesPanel",
      "debugToggleButton",
      "pauseToggleButton",
      "telemetryPanel",
      "addonAuditPanel",
      "devToolsPanel",
      "addonsLabel",
      "addonsPanel",
    },
  }

  local function _golApplyTab(tabName)
    -- Header stays visible, only content switches
    for _, id in ipairs(_golHeaderAlways) do _golSetVisible(id, true) end
    for _, id in ipairs(_golAllSections) do _golSetVisible(id, false) end

    local group = _golTabGroups[tabName] or _golTabGroups.main
    for _, id in ipairs(group) do _golSetVisible(id, true) end


    -- If DEV is disabled, hide the DevTools panel even in Debug tab.
    if tabName == "debug" and type(CFG) == "table" and type(CFG.devTools) == "table" and CFG.devTools.enabled == false then
      _golSetVisible("devToolsPanel", false)
    end
    -- Mark active tab
    local btnMain      = getUiChild(win, "tabMain")
local btnLoot      = getUiChild(win, "tabLoot")
local btnSpellRune = getUiChild(win, "tabSpellRune")

_golSetBtnOn(btnMain, tabName == "main")
_golSetBtnOn(btnLoot, tabName == "loot")
_golSetBtnOn(btnSpellRune, tabName == "spell_rune")
  end

  local function _golApplyCompactMode(compact)
    local compactBtn = getUiChild(win, "compactToggleButton")
    if compactBtn and type(compactBtn.setText) == "function" then
      pcall(function() compactBtn:setText(compact and "Compact: ON" or "Compact: OFF") end)
    end

    -- In compact: hide tabs, show only essential Main widgets.
    if compact then
      _golSetVisible("tabBarPanel", false)

      for _, id in ipairs(_golAllSections) do _golSetVisible(id, false) end
      _golSetVisible("pauseStatusLabel", true)
      _golSetVisible("pauseToggleButton", true)
      _golSetVisible("debugToggleButton", true)
      _golSetVisible("togglesPanel", true)
      _golSetVisible("rotationEditButton", true)
    else
      _golSetVisible("tabBarPanel", true)
      _golApplyTab(CFG.ui.activeTab)
    end
  end

  local function _golSetActiveTab(tabName)
  tabName = tostring(tabName or "main"):lower()

  -- migration / aliases (stare zakładki -> nowe)
  if tabName == "bp" or tabName == "backpacks" then tabName = "loot" end
  if tabName == "rotation" or tabName == "debug" or tabName == "addons" then tabName = "spell_rune" end
  if tabName == "spell" or tabName == "spells" or tabName == "rune" or tabName == "spell_rune" or tabName == "spellrune" then
    tabName = "spell_rune"
  end

  if not _golTabGroups[tabName] then tabName = "main" end

  CFG.ui.activeTab = tabName
  requestSaveConfig()

  if CFG.ui.compactMode then
    CFG.ui.compactMode = false
    requestSaveConfig()
  end

  _golApplyCompactMode(false)
end


  -- Bind compact toggle
  local _compactBtn = getUiChild(win, "compactToggleButton")
  if _compactBtn then
    _compactBtn.onClick = function()
      CFG.ui.compactMode = not CFG.ui.compactMode
      requestSaveConfig()
      _golApplyCompactMode(CFG.ui.compactMode)
    end
  end


  -- v11G: Narrow mode (persisted)
  local function _golApplyNarrowMode(narrow)
    local nb = getUiChild(win, "narrowToggleButton")
    if nb and type(nb.setText) == "function" then
      pcall(function() nb:setText(narrow and "Narrow: ON" or "Narrow: OFF") end)
    end

    local function setTabW(w)
      local ids = {"tabMain","tabLoot","tabSpellRune"}
      for _, id in ipairs(ids) do
        local b = getUiChild(win, id)
        if b and type(b.setWidth) == "function" then pcall(function() b:setWidth(w) end) end
      end
    end

    local function setTabText(map)
      for id, text in pairs(map) do
        local b = getUiChild(win, id)
        if b and type(b.setText) == "function" then
          pcall(function() b:setText(text) end)
        end
      end
    end


    if narrow then
      if type(CFG.ui) ~= "table" then CFG.ui = {} end
      if type(CFG.ui._wideWidth) ~= "number" then
        local ok, w = callAny(win, "getWidth")
        if ok and type(w) == "number" then CFG.ui._wideWidth = w end
      end
      local target = tonumber(CFG.ui.narrowWidth) or 240
      pcall(function() callAny(win, "setWidth", target) end)
      setTabW(34)
      setTabText({tabMain='M', tabAddons='A', tabLoot='L', tabRotation='R', tabBackpacks='B', tabDebug='D'})
    else
      local restore = tonumber((type(CFG.ui) == "table" and CFG.ui._wideWidth)) or 270
      pcall(function() callAny(win, "setWidth", restore) end)
      setTabW(38)
      setTabText({tabMain='Main', tabAddons='Add', tabLoot='Loot', tabRotation='Rot', tabBackpacks='BP', tabDebug='Dbg'})
    end
  end

  local _narrowBtn = getUiChild(win, "narrowToggleButton")
  if _narrowBtn then
    _narrowBtn.onClick = function()
      CFG.ui = (type(CFG.ui) == "table") and CFG.ui or {}
      CFG.ui.narrowMode = not (CFG.ui.narrowMode == true)
      if CFG.ui.narrowMode then
        local ok, w = callAny(win, "getWidth")
        if ok and type(w) == "number" then CFG.ui._wideWidth = w end
      end
      requestSaveConfig()
      _golApplyNarrowMode(CFG.ui.narrowMode == true)
    end

    _golApplyNarrowMode(CFG.ui.narrowMode == true)
  end

  -- Bind tab buttons
  local function _bindTab(id, tabName)
    local b = getUiChild(win, id)
    if not b then return end
    b.onClick = function() _golSetActiveTab(tabName) end
  end

  _bindTab("tabMain", "main")
  _bindTab("tabLoot", "loot")
  _bindTab("tabSpellRune", "spell_rune")

  -- Apply initial view
  G._uiApplyView = function()
    _golApplyCompactMode(CFG.ui.compactMode)
  end

  local function hkValid(s)
    if type(s) ~= "string" then return false end
    if s == "" then return false end
    if #s > 28 then return false end
    -- Allowed: letters/digits/_/+/- (e.g. Ctrl+L, Shift+F6, Ctrl+Numpad4)
    return s:match("^[%w%+%-%_]+$") ~= nil
  end

  local function hkGetCfg()
    if type(CFG.ui) ~= "table" then CFG.ui = {} end
    if type(CFG.ui.hotkeys) ~= "table" then CFG.ui.hotkeys = {} end
    local cur = CFG.ui.hotkeys
    local def = hkDefaults()
    return {
      loot  = hkNormalize(cur.loot  or def.loot),
      heal  = hkNormalize(cur.heal  or def.heal),
      mana  = hkNormalize(cur.mana  or def.mana),
      panic = hkNormalize(cur.panic or def.panic),
    }
  end

  local function hkSetStatus(msg, ok)
    local lbl = getUiChild(win, "hkStatusLabel")
    if lbl then
      if type(lbl.setText) == "function" then
        pcall(function() lbl:setText(msg or "") end)
      end
      local color = (ok == false) and "#ff5555" or "#00ff00"
      -- Some forks use setColor, others setTextColor.
      if type(lbl.setColor) == "function" then
        pcall(function() lbl:setColor(color) end)
      elseif type(lbl.setTextColor) == "function" then
        pcall(function() lbl:setTextColor(color) end)
      end
    end

    -- Auto-clear after a short time so the label doesn't "stick" forever.
    if removeEvent and G._hkStatusEv then pcall(removeEvent, G._hkStatusEv) end
    if scheduleEvent and (msg and msg ~= "") then
      local ev = scheduleEvent(function()
        G._hkStatusEv = nil
        local l = getUiChild(win, "hkStatusLabel")
        if l and type(l.setText) == "function" then pcall(function() l:setText("") end) end
      end, 1600)
      G._hkStatusEv = safeTrackEvent(ev, "GoL.hkStatus")
    end
  end

  local function hkRefreshUi()
    local hk = hkGetCfg()
    local eLoot  = getUiChild(win, "hkLootEdit")
    local eHeal  = getUiChild(win, "hkHealEdit")
    local eMana  = getUiChild(win, "hkManaEdit")
    local ePanic = getUiChild(win, "hkPanicEdit")

    if eLoot  and type(eLoot.setText)  == "function" then pcall(function() eLoot:setText(hk.loot) end) end
    if eHeal  and type(eHeal.setText)  == "function" then pcall(function() eHeal:setText(hk.heal) end) end
    if eMana  and type(eMana.setText)  == "function" then pcall(function() eMana:setText(hk.mana) end) end
    if ePanic and type(ePanic.setText) == "function" then pcall(function() ePanic:setText(hk.panic) end) end
  end

  -- v10l PRO: while editing hotkey fields, suppress hotkey callbacks
  local function hkIsEditingFocused()
    if not (g_ui and type(g_ui.getFocusedWidget) == "function") then return (G._hkEditing == true) end
    local ok, fw = pcall(g_ui.getFocusedWidget)
    if not ok or not fw then return (G._hkEditing == true) end

    local okId, id = callAny(fw, "getId")
    id = okId and id and tostring(id) or ""
    if id == "hkLootEdit" or id == "hkHealEdit" or id == "hkManaEdit" or id == "hkPanicEdit" then
      return true
    end
    return (G._hkEditing == true)
  end

  local function hkBindFocusWatchers()
    local function bindEdit(edit)
      if not edit or edit._golHkFocusBound then return end
      edit._golHkFocusBound = true

      edit.onFocusChange = function(_, focused)
        G._hkEditing = (focused == true)
        -- In case focus moved between our edits, re-evaluate next tick.
        if scheduleEvent then
          scheduleEvent(function()
            G._hkEditing = hkIsEditingFocused()
          end, 1)
        end
        return true
      end

      -- Clicking inside the edit should also mark editing.
      edit.onMousePress = function(_, _, _)
        G._hkEditing = true
        return false
      end
    end

    bindEdit(getUiChild(win, "hkLootEdit"))
    bindEdit(getUiChild(win, "hkHealEdit"))
    bindEdit(getUiChild(win, "hkManaEdit"))
    bindEdit(getUiChild(win, "hkPanicEdit"))

    -- Seed flag.
    G._hkEditing = hkIsEditingFocused()
  end


  local function hkReadUi()
    local def = hkDefaults()
    local function getTxt(w, fallback)
      if not w then return fallback end
      if type(w.getText) == "function" then
        local ok, t = pcall(function() return w:getText() end)
        if ok and type(t) == "string" then
          t = hkNormalize(t)
          if t ~= "" then return t end
        end
      end
      return fallback
    end

    local eLoot  = getUiChild(win, "hkLootEdit")
    local eHeal  = getUiChild(win, "hkHealEdit")
    local eMana  = getUiChild(win, "hkManaEdit")
    local ePanic = getUiChild(win, "hkPanicEdit")

    return {
      loot  = getTxt(eLoot,  def.loot),
      heal  = getTxt(eHeal,  def.heal),
      mana  = getTxt(eMana,  def.mana),
      panic = getTxt(ePanic, def.panic),
    }
  end

  local function hkMapString(hk)
    hk = (type(hk) == "table") and hk or {}
    return string.format("Loot=%s Heal=%s Mana=%s Panic=%s",
      tostring(hk.loot or "?"), tostring(hk.heal or "?"), tostring(hk.mana or "?"), tostring(hk.panic or "?"))
  end

  local function rebindNow()
    local okU, errU = true, nil
    if type(unbindHotkeys) == "function" then okU, errU = pcall(unbindHotkeys) end
    local okB, errB = true, nil
    if type(bindHotkeys) == "function" then okB, errB = pcall(bindHotkeys) end
    local ok = (okU and okB)
    local err = (not okU and errU) or (not okB and errB)
    return ok, err
  end

  local function hkApply()
    G._hkEditing = false
    local hk = hkReadUi()
    local bad = {}
    if not hkValid(hk.loot)  then table.insert(bad, "loot") end
    if not hkValid(hk.heal)  then table.insert(bad, "heal") end
    if not hkValid(hk.mana)  then table.insert(bad, "mana") end
    if not hkValid(hk.panic) then table.insert(bad, "panic") end

    if #bad > 0 then
      hkSetStatus("Invalid: " .. table.concat(bad, ", "), false)
      return
    end

    if type(CFG.ui) ~= "table" then CFG.ui = {} end
    CFG.ui.hotkeys = hk

    if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end
    local okR, errR = rebindNow()
    local map = hkMapString(hk)
    if okR then
      hkSetStatus("Bound: " .. map, true)
      pushUiLog("Hotkeys bound: " .. map)
      print("[GoL][Hotkeys] Bound: " .. map)
    else
      hkSetStatus("Failed: " .. tostring(errR or "rebind"), false)
      pushUiLog("Hotkeys failed: " .. tostring(errR or "rebind"))
      print("[GoL][Hotkeys] Failed: " .. tostring(errR or "rebind"))
    end
  end

  local function hkReset()
    G._hkEditing = false
    if type(CFG.ui) ~= "table" then CFG.ui = {} end
    CFG.ui.hotkeys = hkDefaults()
    hkRefreshUi()
    if type(requestSaveConfig) == "function" then pcall(requestSaveConfig) end
    local okR, errR = rebindNow()
    local map = hkMapString(hkDefaults())
    if okR then
      hkSetStatus("Bound: " .. map, true)
      pushUiLog("Hotkeys reset/bound: " .. map)
      print("[GoL][Hotkeys] Reset/Bound: " .. map)
    else
      hkSetStatus("Failed: " .. tostring(errR or "rebind"), false)
      pushUiLog("Hotkeys reset failed: " .. tostring(errR or "rebind"))
      print("[GoL][Hotkeys] Reset FAILED: " .. tostring(errR or "rebind"))
    end
  end

  if G._hkUiBound ~= win then
    G._hkUiBound = win
    local bApply = getUiChild(win, "hkApplyButton")
    if bApply then bApply.onClick = function() hkApply() end end
    local bReset = getUiChild(win, "hkResetButton")
    if bReset then bReset.onClick = function() hkReset() end end

    hkRefreshUi()
    hkBindFocusWatchers()
    hkSetStatus("", true)
  else
    hkRefreshUi()
    hkBindFocusWatchers()
  end


  local function bind(id, fn)
    local b = getUiChild(win, id)
    if not b then return end
    b.onClick = function()
      pcall(fn)
      if string.find(id, "^addon_") then
        pcall(updateAddonButtons, win)
      end
    end
  end

  bind("healToggleButton", function()
    G.flags.heal = not G.flags.heal
    if shouldRun() then startLoop() else stopLoop() end
    CFG.healEnabled = (G.flags.heal == true)
    pcall(saveConfig)
    refreshButtons()
  end)

  bind("manaToggleButton", function()
    G.flags.mana = not G.flags.mana
    if shouldRun() then startLoop() else stopLoop() end
    CFG.manaEnabled = (G.flags.mana == true)
    pcall(saveConfig)
    refreshButtons()
  end)

  -- Loot
  bind("lootToggleButton", function()
    G.flags.loot = not G.flags.loot
    if shouldRun() then startLoop() else stopLoop() end
    CFG.lootEnabled = (G.flags.loot == true)
    pcall(saveConfig)
    refreshButtons()
  end)

  bind("hudToggleButton", function()
    CFG.hudEnabled = not CFG.hudEnabled
    if not CFG.hudEnabled then
      if widgetAlive(G._hud) then pcall(function() G._hud:destroy() end) end
      G._hud = nil
    end
    pcall(saveConfig)
    refreshButtons()
  end)

  bind("lootModeButton", function()
    if not (CFG and CFG.loot) then return end
    local m = tostring(CFG.loot.mode or "list"):lower()
    CFG.loot.mode = (m == "all") and "list" or "all"
    pushUiLog("Loot mode: " .. tostring(CFG.loot.mode))
    pcall(saveConfig)
    refreshButtons()
  end)


-- Loot list editor
bind("lootRemoveLastButton", function()
  local removed = removeLastLootId()
  if removed then
    pushUiLog("Loot ID removed: " .. tostring(removed))
    pcall(saveConfig)
  else
    pushUiLog("Loot list empty")
  end
  updateLootListUi(win)
  refreshButtons()
end)

bind("lootClearListButton", function()
  clearLootIds()
  pushUiLog("Loot list cleared")
  pcall(saveConfig)
  updateLootListUi(win)
  refreshButtons()
end)


-- Loot drop target (hard-bind; OTUI @onDrop can be flaky across builds)
do
  local drop = getUiChild(win, "lootDropItem")
  if drop then
    if CFG and CFG.debug then pushUiLog("[GoL] LootDrop bound") end
    drop.onDrop = function(widget, draggedWidget, mousePos)
      return GiftOfLife.onLootItemDrop(drop, draggedWidget, mousePos)
    end

    drop.onMouseRelease = function(widget, mousePos, button)
      -- Some builds don't trigger onDrop for custom widgets; treat mouse release as a drop attempt.
      local dw = nil
      if g_ui then
        local ok, w = callAny(g_ui, "getDraggingWidget")
        if ok then dw = w end
      end
      return GiftOfLife.onLootItemDrop(drop, dw, mousePos)
    end

    drop.onMousePress = function(widget, mousePos, button)
      if CFG and CFG.debug then pushUiLog("[GoL] LootDrop press") end
      return false
    end

    _golArmLootDropTarget()
  end
end



  
  

-- Loot ignore drop target (adds to IGNORE list)
do
  local drop = getUiChild(win, "noLootDropItem")
  if drop then
    drop.onDrop = function(widget, draggedWidget, mousePos)
      return GiftOfLife.onIgnoreItemDrop(drop, draggedWidget, mousePos)
    end

    drop.onMouseRelease = function(widget, mousePos, button)
      local dw = nil
      if g_ui then
        local ok, w = callAny(g_ui, "getDraggingWidget")
        if ok then dw = w end
      end
      if dw then
        return GiftOfLife.onIgnoreItemDrop(drop, dw, mousePos)
      end
      return false
    end
  end
end

-- Loot routing slots (MAIN/STACK/NONSTACK)
do
  local function bindSlot(slotId, kind, clearBtnId)
    local slot = getUiChild(win, slotId)
    if slot then
      slot.onDrop = function(widget, draggedWidget, mousePos)
        return GiftOfLife.onLootRouteDrop(kind, slot, draggedWidget, mousePos)
      end
      slot.onMouseRelease = function(widget, mousePos, button)
        local dw = nil
        if g_ui then
          local ok, w = callAny(g_ui, "getDraggingWidget")
          if ok then dw = w end
        end
        if dw then
          return GiftOfLife.onLootRouteDrop(kind, slot, dw, mousePos)
        end
        return false
      end
    end

    local clr = getUiChild(win, clearBtnId)
    if clr then
      clr.onClick = function()
        GiftOfLife.setLootBag(kind, 0)
      end
    end
  end

  bindSlot("lootBagMainSlot", "main", "lootBagMainClear")
  bindSlot("lootBagStackSlot", "stack", "lootBagStackClear")
  bindSlot("lootBagNonStackSlot", "nonstack", "lootBagNonStackClear")
  GiftOfLife.updateLootBagConfigUi(win)
end

-- Addons (top 5)
  local function toggleAddon(name)
    if not CFG then return end
    CFG.addonsEnabled = (CFG.addonsEnabled ~= false)
    CFG.addons = CFG.addons or {}
    CFG.addons[name] = CFG.addons[name] or { enabled = false }

    local newState = not (CFG.addons[name].enabled == true)
    CFG.addons[name].enabled = newState

    pcall(saveConfig)

    -- v10c: per-addon toggle (no shutdownAll, no purge, no restart of other addons)
    if _G.GoLAddons then
      if newState then
        if type(_G.GoLAddons.enable) == "function" then
          pcall(_G.GoLAddons.enable, name)
        else
          -- fallback (older manager): soft reload
          local soft = { purge = false }
          if type(_G.GoLAddons.reloadEnabled) == "function" then pcall(_G.GoLAddons.reloadEnabled, soft) end
        end
      else
        if type(_G.GoLAddons.disable) == "function" then
          pcall(_G.GoLAddons.disable, name)
        else
          local soft = { purge = false }
          if type(_G.GoLAddons.reloadEnabled) == "function" then pcall(_G.GoLAddons.reloadEnabled, soft) end
        end
      end
    end

    pushUiLog(string.format("%s: %s", tostring(name), newState and "ON" or "OFF"))
    refreshButtons()
  end

  bind("addon_panic_guard", function() toggleAddon("panic_guard") end)
  bind("addon_smart_target", function() toggleAddon("smart_target") end)
  bind("addon_combat_modes", function() toggleAddon("combat_modes") end)
  bind("addon_smart_kite", function() toggleAddon("smart_kite") end)
  bind("addon_autospell_rotation", function() toggleAddon("autospell_rotation") end)
-- Debug / telemetry toggle (v10b)
bind("debugToggleButton", function()
  G.ui = (type(G.ui) == "table") and G.ui or {}
  G.ui.debugVisible = not (G.ui.debugVisible == true)
  CFG.ui = CFG.ui or {}
  CFG.ui.debugVisible = (G.ui.debugVisible == true)
  pcall(saveConfig)
  refreshButtons()
end)

-- Manual pause (v10d): toggles only the "manual" pause source.
bind("pauseToggleButton", function()
  local t = nowMs()
  local stack = G._pauseStack
  local e = (type(stack) == "table") and stack["manual"] or nil
  local active = (type(e) == "table") and (t < (tonumber(e.untilMs) or 0))

  if active then
    if type(G.clearPause) == "function" then pcall(G.clearPause, "manual") end
    pushUiLog("manual_pause: OFF")
  else
    if type(G.pause) == "function" then pcall(G.pause, "Manual pause", 10000, "manual", 10) end
    pushUiLog("manual_pause: ON (10s)")
  end

  refreshButtons()
end)


-- Backpack picker (MAIN/LOOT/STACK)
  bind("bpButton0", function() openBpPicker("main") end)
  bind("bpButton1", function() openBpPicker("loot") end)
  bind("bpButton2", function() openBpPicker("stack") end)

  pcall(function() win:show() end)
  pcall(function() win:raise() end)

  refreshButtons()
  updateBpRoleButtons()
  if type(G._uiApplyView) == "function" then pcall(G._uiApplyView) end


  -- Start loop automatically if any toggle is ON
  if shouldRun() then startLoop() else stopLoop() end
end

function _G.GiftOfLife.panicOff()
  G.flags.heal = false
  G.flags.mana = false
  G.flags.loot = false
  stopLoop()
  pushUiLog("PANIC OFF (all toggles OFF)")
  refreshButtons()
end

local function getKeyScope()
  -- Note: in Lua, 'return' must be the last statement in a block, so keep returns final.
  if modules and modules.game_interface then
    if type(modules.game_interface.getRootPanel) == "function" then
      local p = modules.game_interface.getRootPanel()
      if p then return p end
    end
    if type(modules.game_interface.getMapPanel) == "function" then
      local p = modules.game_interface.getMapPanel()
      if p then return p end
    end
  end

  if g_ui and type(g_ui.getRootWidget) == "function" then
    local w = g_ui.getRootWidget()
    if w then return w end
  end

  if rootWidget then return rootWidget end
  return nil
end

bindHotkeys = function()
  if not (CFG and CFG.ui and CFG.ui.hotkeysEnabled) then return end
  if not g_keyboard then return end
  if type(g_keyboard.bindKeyDown) ~= "function" and type(g_keyboard.bindKeyPress) ~= "function" and type(g_keyboard.bindKey) ~= "function" then
    return
  end

  -- Prevent stacking binds on reload.
  if G._hotkeysBound == true then return end

  local scope = getKeyScope()

  local hk = (CFG.ui and CFG.ui.hotkeys) or {}
  local hkLoot = (type(hk.loot) == "string" and hk.loot ~= "") and hk.loot or "F6"
  local hkHeal = (type(hk.heal) == "string" and hk.heal ~= "") and hk.heal or "F7"
  local hkMana = (type(hk.mana) == "string" and hk.mana ~= "") and hk.mana or "F8"
  local hkPanic = (type(hk.panic) == "string" and hk.panic ~= "") and hk.panic or "Shift+F6"


  local function tryBindKey(key, cb, scopeWidget)
    if not g_keyboard then return false end

    local candidates = {
      g_keyboard.bindKeyDown,
      g_keyboard.bindKeyPress,
      g_keyboard.bindKey,
    }

    for _, fn in ipairs(candidates) do
      if type(fn) == "function" then
        -- Try with scope first (some forks require it), then without.
        local ok = pcall(fn, key, cb, scopeWidget)
        if ok then return true end
        ok = pcall(fn, key, cb)
        if ok then return true end
      end
    end
    return false
  end

  G._hotkeyScope = scope
    G._hotkeyKeys = { hkLoot, hkHeal, hkMana, hkPanic }

  local anyBound = false

  anyBound = tryBindKey(hkLoot, function()
    if G._hkEditing == true then return end
    G.flags.loot = not G.flags.loot
    pushUiLog("Loot: " .. (G.flags.loot and "ON" or "OFF"))
    if shouldRun() then startLoop() else stopLoop() end
    refreshButtons()
  end, scope)

  anyBound = anyBound or tryBindKey(hkHeal, function()
    if G._hkEditing == true then return end
    G.flags.heal = not G.flags.heal
    pushUiLog("Heal: " .. (G.flags.heal and "ON" or "OFF"))
    if shouldRun() then startLoop() else stopLoop() end
    refreshButtons()
  end, scope)

  anyBound = anyBound or tryBindKey(hkMana, function()
    if G._hkEditing == true then return end
    G.flags.mana = not G.flags.mana
    pushUiLog("Mana: " .. (G.flags.mana and "ON" or "OFF"))
    if shouldRun() then startLoop() else stopLoop() end
    refreshButtons()
  end, scope)

  anyBound = anyBound or tryBindKey(hkPanic, function()
    if G._hkEditing == true then return end
    _G.GiftOfLife.panicOff()
  end, scope)

  G._hotkeysBound = (anyBound == true)
  if G._hotkeysBound then
    pushUiLog(string.format("Hotkeys: %s=Loot, %s=Heal, %s=Mana, %s=PanicOff", tostring(hkLoot), tostring(hkHeal), tostring(hkMana), tostring(hkPanic)))
  else
    pushUiLog("Hotkeys: FAILED to bind (check client key system)")
  end
end

unbindHotkeys = function()
  if not g_keyboard then return end
  local keys = G._hotkeyKeys or { "F6", "F7", "F8", "Shift+F6" }
  local scope = G._hotkeyScope

  local function tryUnbind(fnName, key)
    local fn = g_keyboard[fnName]
    if type(fn) ~= "function" then return end
    -- Try common signatures.
    local ok = pcall(fn, key, scope)
    if ok then return end
    pcall(fn, key)
  end

  for _, key in ipairs(keys) do
    tryUnbind("unbindKeyDown", key)
    tryUnbind("unbindKeyPress", key)
    tryUnbind("unbindKey", key)
  end

  G._hotkeysBound = false
end

-- Public: clean shutdown (safe to call before reloading the module).
function _G.GiftOfLife.shutdown()
  -- Stop loop/timers.
  pcall(function() stopLoop() end)
  if G._evt and removeEvent then pcall(function() removeEvent(G._evt) end) end
  G._evt = nil

  -- Cancel pending boot event (prevents stale callbacks from older reloads).
  if type(removeEvent) == "function" and G._bootEv then pcall(function() removeEvent(G._bootEv) end) end
  G._bootEv = nil

  G.enabled = false

  -- Hotkeys.
  pcall(function() unbindHotkeys() end)

  -- Context menu hook (avoid duplicates on reload).
  pcall(function() uninstallLootContextMenuHook() end)

  local function destroyWidget(w)
    if widgetAlive(w) then pcall(function() w:destroy() end) end
  end

  -- HUD labels (destroy by refs).
  destroyWidget(G._hud)
  destroyWidget(G._statusLabel)
  G._hud = nil
  G._statusLabel = nil

  -- HUD labels (destroy by id, in case refs were lost).
  do
    local parent = getHudParent()
    if widgetAlive(parent) then
      local ok, w = pcall(function() return parent:recursiveGetChildById("GiftOfLifeHud") end)
      if ok then destroyWidget(w) end
      ok, w = pcall(function() return parent:recursiveGetChildById("GiftOfLifeStatus") end)
      if ok then destroyWidget(w) end
    end
  end


  -- Auxiliary windows (profile picker / rotation editor).
  destroyWidget(G._profilePicker)
  G._profilePicker = nil
  destroyWidget(G._rotationEditorWin)
  G._rotationEditorWin = nil

  -- Main window (destroy by ref).
  destroyWidget(G._window)
  G._window = nil

  -- Main window (destroy by id, in case ref was lost).
  do
    local root = nil
    if modules and modules.game_interface and modules.game_interface.getRootPanel then
      local ok, r = pcall(modules.game_interface.getRootPanel)
      if ok then root = r end
    end
    if not root and g_ui and g_ui.getRootWidget then root = g_ui.getRootWidget() end
    if widgetAlive(root) then
      local ok, w = pcall(function() return root:recursiveGetChildById("giftOfLifeWindow") end)
      if ok then destroyWidget(w) end
    end
  end
end

-- Delay UI init until game interface exists
local function _gol_boot()
  -- If this callback is from an older dofile(), abort.
  if _G.GiftOfLife ~= G then return end
  if G._loadToken ~= LOAD_TOKEN then return end
  if (tonumber(_G.GoL_ReloadSeq) or 0) ~= LOAD_SEQ then return end

  bindButtons()
  pcall(function() installLootContextMenuHook() end)
  bindHotkeys()
  startTelemetryLoop()
end

-- Public boot entrypoint (called from init.lua after all modules loaded)
function G.boot()
  -- Prevent double-boot within the same load.
  if G._bootedToken == LOAD_TOKEN and G._bootedSeq == LOAD_SEQ then
    return true
  end

  -- If the game interface root panel isn't ready yet, retry shortly.
  local rootOk = false
  if modules and modules.game_interface and type(modules.game_interface.getRootPanel) == "function" then
    local ok, r = pcall(modules.game_interface.getRootPanel)
    if ok and r then rootOk = true end
  end

  if not rootOk and type(scheduleEvent) == "function" then
    if type(removeEvent) == "function" and G._bootEv then
      pcall(function() removeEvent(G._bootEv) end)
    end
    G._bootEv = safeTrackEvent(scheduleEvent(function()
      pcall(G.boot)
    end, 50), "GoL.bootRetry")
    return false
  end

  G._bootedToken = LOAD_TOKEN
  G._bootedSeq = LOAD_SEQ
  _gol_boot()
  return true
end
local hp = getHudParent()
if hp then pcall(function() print("[GiftOfLife] HUD parent ok: "..tostring(hp:getId())) end) end
pushUiLog("Loaded")
print("[GiftOfLife] loaded")
