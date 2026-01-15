-- dev/ingame_editor.lua
-- GoL v12 PRO - Dev Tools (Dbg tab only)
-- English comments only.

_G.GoLDev = _G.GoLDev or {}
local D = _G.GoLDev
local G = _G.GiftOfLife or {}


D._editorWins = D._editorWins or {}
D._catalogWin = D._catalogWin or nil

local function _widgetAlive(w)
  if not w then return false end
  if type(w.isDestroyed) == "function" then
    local ok, dead = pcall(w.isDestroyed, w)
    if ok and dead then return false end
  end
  return true
end

local function _track(w, label)
  if _G.GoL and _G.GoL.LeakGuardPP and type(_G.GoL.LeakGuardPP.trackWidget) == "function" then
    pcall(_G.GoL.LeakGuardPP.trackWidget, w, label)
  end
  if _G.GoLLeakGuard and type(_G.GoLLeakGuard.track) == "function" then
    pcall(_G.GoLLeakGuard.track, w)
  end
end


local function _destroy(w)
  if not _widgetAlive(w) then return end
  pcall(function() if type(w.destroyChildren) == "function" then w:destroyChildren() end end)
  pcall(function() if type(w.destroy) == "function" then w:destroy() end end)
end

-- Prefer game_interface rootPanel when available (most OTC modules load UI there).
function D.getUiRoot()
  if modules and modules.game_interface and type(modules.game_interface.getRootPanel) == "function" then
    local ok, rp = pcall(modules.game_interface.getRootPanel)
    if ok and rp then return rp end
  end
  if g_ui and type(g_ui.getRootWidget) == "function" then
    local ok, rw = pcall(g_ui.getRootWidget)
    if ok then return rw end
  end
  return nil
end

local function _bfsFindById(root, wantedId)
  if not root or type(root.getChildren) ~= "function" then return nil end
  local q = { root }
  local qi = 1
  while qi <= #q do
    local w = q[qi]; qi = qi + 1
    local okId, wid = pcall(function() return w.getId and w:getId() end)
    if okId and wid == wantedId then return w end
    local okCh, ch = pcall(function() return w:getChildren() end)
    if okCh and type(ch) == "table" then
      for _, c in ipairs(ch) do q[#q+1] = c end
    end
  end
  return nil
end

local function _getById(root, wantedId)
  if not root or type(wantedId) ~= "string" or wantedId == "" then return nil end

  -- Prefer recursive lookup when available (some forks have non-recursive getChildById).
  if type(root.recursiveGetChildById) == "function" then
    local ok, w = pcall(root.recursiveGetChildById, root, wantedId)
    if ok and w then return w end
  end

  if type(root.getChildById) == "function" then
    local ok, w = pcall(root.getChildById, root, wantedId)
    if ok and w then return w end
  end

  -- Last resort: BFS scan.
  return _bfsFindById(root, wantedId)
end

local function _findTextWidget(win, preferredIds)
  if not win then return nil end
  if type(preferredIds) == "table" then
    for _, id in ipairs(preferredIds) do
      local w = _getById(win, id)
      if w and type(w.setText) == "function" then return w end
    end
  end
  -- Fallback: BFS find first widget that looks like a text area (has setText).
  if type(win.getChildren) ~= "function" then return nil end
  local q = { win }
  local qi = 1
  while qi <= #q do
    local w = q[qi]; qi = qi + 1
    if w and type(w.setText) == "function" and type(w.getText) == "function" then
      return w
    end
    local okCh, ch = pcall(function() return w:getChildren() end)
    if okCh and type(ch) == "table" then
      for _, c in ipairs(ch) do q[#q+1] = c end
    end
  end
  return nil
end



D._mainWin = D._mainWin or nil
D._keys = D._keys or {}
D._events = D._events or {}
D._running = D._running or false
D._lastError = D._lastError or nil

local function nowMs()
  if g_clock and g_clock.millis then return g_clock.millis() end
  return math.floor(os.clock() * 1000)
end

local function _cfgDev()
  if type(_G.CFG) ~= "table" then _G.CFG = {} end
  if type(_G.CFG.dev) ~= "table" then _G.CFG.dev = {} end
  local d = _G.CFG.dev
  if type(d.scripts) ~= "string" then d.scripts = "" end
  if type(d.macros) ~= "string" then d.macros = "" end
  if type(d.hotkeys) ~= "string" then d.hotkeys = "" end
  return d
end

local function _setMainStatus(ok, msg)
  D._lastError = ok and nil or tostring(msg or "unknown error")
  local win = D._mainWin
  if not win or type(win.getChildById) ~= "function" then return end
  local lab = _getById(win, "devStatusLabel")
  if not lab then return end
  if ok then
    pcall(function()
      lab:setText("DEV: READY")
      lab:setColor("#66ff66")
    end)
  else
    pcall(function()
      lab:setText("DEV: ERROR (see console)")
      lab:setColor("#ff6666")
    end)
  end
end

local function _safePrint(s)
  s = tostring(s or "")
  if _G.g_logger and type(_G.g_logger.info) == "function" then
    pcall(function() _G.g_logger.info(s) end)
  else
    pcall(function() print(s) end)
  end
end

local function _unbindAll()
  if g_keyboard and type(g_keyboard.unbindKeyDown) == "function" then
    for _, k in ipairs(D._keys) do
      local key = k and k.key
      if type(key) == "string" and key ~= "" then
        -- Many OTClient forks accept only the key string. (See core modules usage.)
        pcall(function() g_keyboard.unbindKeyDown(key) end)
        -- Some forks accept (key, callback). Try best-effort.
        if k.cb then pcall(function() g_keyboard.unbindKeyDown(key, k.cb) end) end
      end
    end
  end
  D._keys = {}
end

local function _cancelAll()
  if removeEvent and type(removeEvent) == "function" then
    for _, ev in ipairs(D._events) do
      pcall(removeEvent, ev)
    end
  end
  D._events = {}
end

function D.bindMainWindow(win)
  D._mainWin = win
  _setMainStatus(true)
end

function D.clearRuntime()
  D._running = false
  _unbindAll()
  _cancelAll()
end

-- Helper exposed to user code: hotkey("Ctrl+F", function() ... end)
function D.hotkey(key, fn)
  if not (g_keyboard and type(g_keyboard.bindKeyDown) == "function") then
    error("g_keyboard.bindKeyDown is not available")
  end
  if type(key) ~= "string" or key == "" then error("hotkey: key must be a string") end
  if type(fn) ~= "function" then error("hotkey: fn must be a function") end
  g_keyboard.bindKeyDown(key, fn)
  table.insert(D._keys, { key = key, cb = fn })
end

-- Single-fire hotkey (auto-unbind after first run)
function D.singlehotkey(key, fn)
  local fired = false
  D.hotkey(key, function(...)
    if fired then return end
    fired = true
    pcall(fn, ...)
    if g_keyboard and type(g_keyboard.unbindKeyDown) == "function" then
      pcall(function() g_keyboard.unbindKeyDown(key) end)
    end
  end)
end

-- Helper exposed to user code: macro(250, "name", function() ... end)
function D.macro(intervalMs, name, fn)
  if not scheduleEvent then error("scheduleEvent is not available") end
  intervalMs = tonumber(intervalMs) or 1000
  if intervalMs < 10 then intervalMs = 10 end
  if type(fn) ~= "function" then error("macro: fn must be a function") end
  name = tostring(name or ("macro@" .. nowMs()))

  local function tick()
    local ok, err = pcall(fn)
    if not ok then
      _safePrint(string.format("[GoL][Dev] macro '%s' error: %s", name, tostring(err)))
    end
    local ev = scheduleEvent(tick, intervalMs)
    table.insert(D._events, ev)
  end

  local ev = scheduleEvent(tick, intervalMs)
  table.insert(D._events, ev)
end

local function _compileChunk(code, chunkName)
  code = tostring(code or "")
  if code == "" then return nil end
  local f, err
  if loadstring then
    f, err = loadstring(code, chunkName)
  elseif load then
    f, err = load(code, chunkName)
  end
  if not f then return nil, err end

  -- Sandbox: allow all globals but inject helpers.
  local env = setmetatable({
    macro = D.macro,
    hotkey = D.hotkey,
    singlehotkey = D.singlehotkey,
    safePrint = _safePrint,
    GoL = _G.GiftOfLife,
  }, { __index = _G })

  if setfenv then pcall(setfenv, f, env) end
  return f
end

function D.reloadFromState()
  D.clearRuntime()

  local d = _cfgDev()
  local chunks = {
    { name = "scripts", code = d.scripts },
    { name = "macros", code = d.macros },
    { name = "hotkeys", code = d.hotkeys },
  }

  for _, c in ipairs(chunks) do
    local f, err = _compileChunk(c.code, "GoLDev_" .. c.name)
    if f then
      local ok, runErr = pcall(f)
      if not ok then
        _setMainStatus(false, runErr)
        _safePrint(string.format("[GoL][Dev] %s: ERROR: %s", c.name, tostring(runErr)))
        return false, runErr
      end
    elseif err and tostring(err) ~= "" then
      _setMainStatus(false, err)
      _safePrint(string.format("[GoL][Dev] %s: COMPILE ERROR: %s", c.name, tostring(err)))
      return false, err
    end
  end

  D._running = true
  _setMainStatus(true)
  _safePrint("[GoL][Dev] reload OK")
  return true
end

local function _ensureEditor(kind)
  if not g_ui or type(g_ui.getRootWidget) ~= "function" then return nil, "g_ui root is not available" end
  local root = D.getUiRoot()
  if not root then return nil, "root widget is nil" end
  local win = g_ui.createWidget("GoLDevEditorWindow", root)
  if not win then return nil, "failed to create GoLDevEditorWindow" end
  pcall(function() win:setId("GoLDevEditor_" .. tostring(kind)) end)
  _track(win, "GoLDevEditor:" .. tostring(kind))
  D._editorWins = D._editorWins or {}
  D._editorWins[kind] = win
  -- Ensure window close button actually destroys the widget (not only hides)
  pcall(function()
    win.onClose = function()
      _destroy(win)
      if D._editorWins then D._editorWins[kind] = nil end
      return true
    end
  end)

  win:raise()
  win:focus()
  win:show()

  local title = "GoL Dev Editor"
  local desc = ""
  if kind == "hotkeys" then
    title = "Ingame hotkey editor"
    desc = "Use hotkey('Ctrl+X', function() ... end). Click Save & Reload to apply."
  elseif kind == "macros" then
    title = "Ingame macro editor"
    desc = "Use macro(250, 'name', function() ... end). Click Save & Reload to apply."
  elseif kind == "scripts" then
    title = "Ingame script editor"
    desc = "Any Lua code. Click Save & Reload to apply."
  end

  pcall(function() win:setText(title) end)
  local dlab = _getById(win, "devEditorDesc")
  if dlab then pcall(function() dlab:setText(desc) end) end

  return win
end

local function _exampleFor(kind)
  if kind == "hotkeys" then
    return [[
-- Example: toggle GoL HUD (if available)
hotkey('Ctrl+H', function()
  if GoL and type(GoL.toggleHud) == 'function' then
    GoL.toggleHud()
  else
    safePrint('[GoL][Dev] GoL.toggleHud not available')
  end
end)
]]
  elseif kind == "macros" then
    return [[
-- Example: print your position every 2s
macro(2000, 'pos', function()
  if g_game and g_game.getLocalPlayer then
    local p = g_game.getLocalPlayer()
    if p and p.getPosition then
      local pos = p:getPosition()
      safePrint(string.format('[GoL][Dev] pos=%d,%d,%d', pos.x, pos.y, pos.z))
    end
  end
end)
]]
  else
    return [[
-- Example: safe probe
safePrint('[GoL][Dev] hello from scripts')
]]
  end
end

function D.openEditor(kind)
  kind = tostring(kind or "scripts")
  -- Reuse existing window if already open (prevents leaks on repeated clicks)
  if D._editorWins and _widgetAlive(D._editorWins[kind]) then
    local win0 = D._editorWins[kind]
    pcall(function() win0:show(); win0:raise(); win0:focus() end)
    return
  end

  local win, err = _ensureEditor(kind)
  if not win then _safePrint("[GoL][Dev] openEditor failed: " .. tostring(err)); return end

  local d = _cfgDev()
  local te = _getById(win, "devEditorText")
  if te then pcall(function() te:setText(d[kind] or "") end) end

  local function saveOnly()
    local txt = ""
    if te then
      local ok, v = pcall(te.getText, te)
      if ok and type(v) == "string" then txt = v end
    end
    d[kind] = txt
    if G and type(G.requestSaveConfig) == "function" then pcall(G.requestSaveConfig) end
  end

  local bSave = _getById(win, "devEditorSaveButton")
  if bSave then bSave.onClick = function() saveOnly(); _safePrint("[GoL][Dev] saved " .. kind) end end

  local bSR = _getById(win, "devEditorSaveReloadButton")
  if bSR then bSR.onClick = function() saveOnly(); D.reloadFromState() end end

  local bIns = _getById(win, "devEditorInsertExampleButton")
  if bIns then
    bIns.onClick = function()
      local ex = _exampleFor(kind)
      if te then
        local cur = ""
        local ok, v = pcall(te.getText, te)
        if ok and type(v) == "string" then cur = v end
        if cur ~= "" and cur:sub(-1) ~= "\n" then cur = cur .. "\n" end
        pcall(function() te:setText(cur .. ex) end)
      end
    end
  end

  local bClose = _getById(win, "devEditorCloseButton")
  if bClose then bClose.onClick = function() pcall(function() win:destroy() end) end end
end


function D.buildCatalogText()
  -- Build the same text that openCatalog renders, but return as a string (useful for debugging).
  -- This intentionally mirrors openCatalog() output.
  local tmp = {}
  local function add(s) table.insert(tmp, s) end
  local function header(s) add(""); add("== " .. s .. " ==") end
  local function item(s) add("  - " .. s) end

  header("Helpers (GoL Dev)")
  item("macro(intervalMs, name, fn)")
  item("hotkey(keyCombo, fn)")
  item("singlehotkey(keyCombo, fn)")
  item("safePrint(msg)")
  item("GoL (GiftOfLife singleton table)")

  if D._lastError and tostring(D._lastError) ~= "" then
    header("Last error")
    add(tostring(D._lastError))
  end

  header("Common OTClient globals")
  local globals = { "g_game", "g_ui", "g_keyboard", "g_resources", "g_map", "g_clock", "g_settings", "modules", "scheduleEvent", "removeEvent" }
  for _, n in ipairs(globals) do add(n) end

  header("Examples")
  add("Hotkey (toggle HUD):")
  add("  hotkey('Ctrl+H', function() if GoL and GoL.toggleHud then GoL.toggleHud() end end)")
  add("Macro (every 1000ms):")
  add("  macro(1000,'tick', function() safePrint('tick') end)")
  add("Safe probe (online check):")
  add("  if g_game and g_game.isOnline and g_game:isOnline() then safePrint('online') end")
  add("BindKeyDown (raw OTClient):")
  add("  if g_keyboard and g_keyboard.bindKeyDown then g_keyboard.bindKeyDown('Ctrl+F', function() safePrint('Ctrl+F') end) end")

  return table.concat(tmp, "\n")
end

-- Backward/compat name: some docs refer to buildCatalog().
function D.buildCatalog()
  return D.buildCatalogText()
end

function D.openCatalog()
  if _widgetAlive(D._catalogWin) then
    pcall(function() D._catalogWin:show(); D._catalogWin:raise(); D._catalogWin:focus() end)
    return
  end

  if not g_ui or type(g_ui.getRootWidget) ~= "function" then return end
  local root = D.getUiRoot()
  local win = g_ui.createWidget("GoLDevCatalogWindow", root)
  if not win then return end
  pcall(function() win:setId("GoLDevCatalog") end)
  _track(win, "GoLDevCatalog")
  D._catalogWin = win
  pcall(function() win.onClose = function() _destroy(win); D._catalogWin = nil; return true end end)

  win:raise(); win:focus(); win:show()

  local out = {}
  local function add(s) table.insert(out, s) end
  local function header(s) add(""); add("== " .. s .. " ==") end
  local function item(s) add("  - " .. s) end

  header("Helpers (GoL Dev)")
  item("macro(intervalMs, name, fn)")
  item("hotkey(keyCombo, fn)")
  item("singlehotkey(keyCombo, fn)")
  item("safePrint(msg)")
  item("GoL (GiftOfLife singleton table)")

  if D._lastError and tostring(D._lastError) ~= "" then
    header("Last error")
    add(tostring(D._lastError))
  end

  header("Common OTClient globals")
  local globals = { "g_game", "g_ui", "g_keyboard", "g_resources", "g_map", "g_clock", "g_settings", "modules", "scheduleEvent", "removeEvent" }
  for _, n in ipairs(globals) do add(n) end

  local function _collectFunctions(obj, kind)
    local names = {}
    local seen = {}

    local function addName(n)
      if type(n) ~= "string" or n == "" then return end
      if seen[n] then return end
      seen[n] = true
      names[#names + 1] = n
    end

    local function scanTable(t)
      if type(t) ~= "table" then return end
      for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "function" then
          addName(k)
        end
      end
    end

    local function probeKnown(obj2, list)
      if not obj2 or type(list) ~= "table" then return end
      for _, n in ipairs(list) do
        local ok, v = pcall(function() return obj2[n] end)
        if ok and type(v) == "function" then
          addName(n)
        end
      end
    end

    -- Direct table scan
    scanTable(obj)

    -- Metatable scan (common for userdata in OTClient)
    local mt = getmetatable(obj)
    scanTable(mt)
    if mt and type(mt.__index) == "table" then
      scanTable(mt.__index)
    end

    -- If __index is a function (typical for C++ userdata), we cannot iterate it.
    -- Use curated probes instead.
    if kind == "g_game" then
      probeKnown(obj, {
        "isOnline","isDead","getLocalPlayer","getFollowCreature","getAttackingCreature",
        "attack","cancelAttack","follow","cancelFollow",
        "use","useWith","open","move","turn","walk","walkTo",
        "talk","sendTalk","sendChannelMessage",
        "setChaseMode","getChaseMode","setFightMode","getFightMode","setSafeFight","getSafeFight",
        "logout","forceLogout","safeLogout"
      })
    elseif kind == "g_keyboard" then
      probeKnown(obj, {
        "bindKeyDown","unbindKeyDown","bindKeyPress","unbindKeyPress",
        "isKeyPressed","getModifiers"
      })
    elseif kind == "g_ui" then
      probeKnown(obj, {
        "getRootWidget","createWidget","loadUI","importStyle","displayUI",
        "createUI","setStyle","getStyle","getWidgetById"
      })
    end

    table.sort(names, function(a,b) return tostring(a) < tostring(b) end)
    return names
  end

  local function listFuncs(title, obj, maxN, kind)
    maxN = tonumber(maxN) or 60
    local ok, names = pcall(_collectFunctions, obj, kind)
    if not ok or type(names) ~= "table" or #names == 0 then
      header(title)
      item("(no methods detected - this fork exposes methods via userdata __index; using API Examples below)")
      return
    end
    header(title)
    for i = 1, math.min(#names, maxN) do
      item(names[i] .. "(...)")
    end
    if #names > maxN then item(string.format("... (%d more)", #names - maxN)) end
  end
listFuncs("g_game (methods)", g_game, 60, "g_game")
  listFuncs("g_keyboard (methods)", g_keyboard, 60, "g_keyboard")
  listFuncs("g_ui (methods)", g_ui, 60, "g_ui")
  listFuncs("GiftOfLife (GoL)", _G.GiftOfLife or {}, 80)
  if _G.GoLAddons then listFuncs("GoLAddons", _G.GoLAddons, 80) end

  header("Examples")
  add("Hotkey (toggle HUD):")
  add("  hotkey('Ctrl+H', function() if GoL and GoL.toggleHud then GoL.toggleHud() end end)")
  add("Macro (every 1000ms):")
  add("  macro(1000,'tick', function() safePrint('tick') end)")
  add("Safe probe (online check):")
  add("  if g_game and g_game.isOnline and g_game:isOnline() then safePrint('online') end")
  add("BindKeyDown (raw OTClient):")
  add("  if g_keyboard and g_keyboard.bindKeyDown then g_keyboard.bindKeyDown('Ctrl+F', function() safePrint('Ctrl+F') end) end")
  local te = _findTextWidget(win, {"devCatalogText","catalogText","devText","text","content","body"})
  if te then
    pcall(function()
      te:setText(table.concat(out, "\n"))
    end)
  end

  local bClose = _getById(win, "devCatalogCloseButton")
  if bClose then bClose.onClick = function() pcall(function() win:destroy() end) end end
end

function D.shutdown(opts)
  opts = opts or {}
  -- Unbind hotkeys
  if g_keyboard and type(g_keyboard.unbindKeyDown) == "function" then
    for _, k in ipairs(D._keys or {}) do
      if k and k.key then pcall(function() g_keyboard.unbindKeyDown(k.key) end) end
    end
  end
  D._keys = {}

  -- Cancel scheduled events
  if type(removeEvent) == "function" then
    for _, ev in ipairs(D._events or {}) do
      if ev then pcall(removeEvent, ev) end
    end
  end
  D._events = {}

  -- Destroy editor/catalog windows if still alive
  if type(D._editorWins) == "table" then
    for kind, win in pairs(D._editorWins) do
      _destroy(win)
      D._editorWins[kind] = nil
    end
  end

  _destroy(D._catalogWin)
  D._catalogWin = nil

  D._running = false
end


function D.init()
  _cfgDev()
  -- Do NOT auto-run (user-selected mode B). Only UI triggers reload.
  _setMainStatus(true)
end
