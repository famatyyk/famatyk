

-- opts can be nil (default purge), boolean (purge?), or table {purge=false}
local function wantPurge(opts)
  if opts == nil then return true end
  if type(opts) == "boolean" then return opts end
  if type(opts) == "table" and opts.purge == false then return false end
  return true
end
-- addons/addons.lua
-- Gift of Life addon manager.
-- Goal: keep NEW features out of gift_of_life.lua.
-- Addons are loaded from gift_of_life/config.lua -> addons table.

_G.GoLAddons = _G.GoLAddons or {}
local M = _G.GoLAddons

M._loaded = M._loaded or {}   -- name -> addon table
M._loadToken = (tonumber(M._loadToken) or 0) + 1
local LOAD_TOKEN = M._loadToken

local function safePrint(msg)
  if print then pcall(function() print(msg) end) end
end

-- v11H: Addon Audit Harness (AAH)
M._audit = M._audit or {}  -- name -> stats

local function nowMs()
  if g_clock and type(g_clock.millis) == "function" then
    local ok, v = pcall(g_clock.millis)
    if ok and type(v) == "number" then return v end
  end
  local ok, v = pcall(function() return os.clock() end)
  if ok and type(v) == "number" then return math.floor(v * 1000) end
  return 0
end

local function tb(err)
  err = tostring(err)
  if debug and type(debug.traceback) == "function" then
    return debug.traceback(err, 2)
  end
  return err
end

local function auditEnsure(name)
  if type(name) ~= "string" or name == "" then return nil end
  local a = M._audit[name]
  if type(a) ~= "table" then
    a = { name = name }
    M._audit[name] = a
  end
  return a
end

local function auditEvent(name, event, ok, err, extra)
  local a = auditEnsure(name)
  if not a then return end
  a.lastEvent = tostring(event or "")
  a.lastEventAtMs = nowMs()
  a.lastOk = (ok == true)
  if ok then
    a.lastError = nil
    a.lastErrorAtMs = nil
  else
    a.lastError = tostring(err or "error")
    a.lastErrorAtMs = a.lastEventAtMs
  end
  if type(extra) == "table" then
    for k, v in pairs(extra) do a[k] = v end
  end
end

-- Public: snapshot for UI
function M.getAuditSnapshot()
  local cfg = M.getCentralConfig()
  local addons = (type(cfg) == "table" and type(cfg.addons) == "table") and cfg.addons or {}
  local order = getAddonOrder(addons)
  -- Ensure audit entries exist for configured addons
  for _, name in ipairs(order) do
    local a = auditEnsure(name)
    local entry = addons[name]
    if a and type(entry) == "table" then
      a.enabledInCfg = (entry.enabled == true)
      a.file = a.file or entry.file
    end
    if a then
      a.loaded = (M._loaded and M._loaded[name] ~= nil) or false
    end
  end
  return {
    nowMs = nowMs(),
    addonsEnabled = (type(cfg) ~= "table" or cfg.addonsEnabled ~= false),
    order = order,
    audit = M._audit,
  }
end


local function tryDofile(paths)
  local lastErr = nil
  for _, p in ipairs(paths) do
    local ok, ret = pcall(dofile, p)
    if ok then return true, ret, p end
    lastErr = ret
  end
  return false, lastErr, nil
end

function M.getCentralConfig()
  -- Prefer flattened config (includes active profile + UI state overlay)
  local ok, cfg = tryDofile({
    "gift_of_life_config.lua",
    "gift_of_life/gift_of_life_config.lua",
    "modules/gift_of_life/gift_of_life_config.lua",
    "config.lua",
    "gift_of_life/config.lua",
    "modules/gift_of_life/config.lua",
  })
  if ok and type(cfg) == "table" then return cfg end
  return {}

end

local function getAddonOrder(addons)
  local order = {}
  if type(addons) ~= "table" then return order end

  if type(addons._order) == "table" and #addons._order > 0 then
    for _, name in ipairs(addons._order) do
      if type(name) == "string" and name ~= "" then
        table.insert(order, name)
      end
    end
    return order
  end

  -- Fallback: collect keys (non-deterministic in Lua pairs).
  for name, _ in pairs(addons) do
    if type(name) == "string" and name:sub(1,1) ~= "_" then
      table.insert(order, name)
    end
  end
  return order
end

local function loadOne(name, entry)
  if type(name) ~= "string" or name == "" then return end
  if type(entry) ~= "table" or entry.enabled ~= true then return end

  local a = auditEnsure(name)
  if a then
    a.enabledInCfg = true
    a.loaded = false
  end

  local file = entry.file
  if type(file) ~= "string" or file == "" then
    file = "addons/" .. name .. ".lua"
  end

  local ok, addonOrErr, loadedPath = tryDofile({
    file,
    "addons/" .. name .. ".lua",
    "gift_of_life/addons/" .. name .. ".lua",
    "modules/gift_of_life/addons/" .. name .. ".lua",
  })

  if not ok then
    safePrint(string.format("[GoL][Addons] load FAIL: %s (%s)", tostring(name), tostring(addonOrErr)))
    auditEvent(name, "load", false, addonOrErr, { file = file, loadedPath = loadedPath, loaded = false })
    return
  end

  local addon = addonOrErr
  if type(addon) ~= "table" then
    safePrint(string.format("[GoL][Addons] load FAIL: %s (did not return table)", tostring(name)))
    auditEvent(name, "load", false, "did not return table", { file = file, loadedPath = loadedPath, loaded = false })
    return
  end

  auditEvent(name, "load", true, nil, { file = file, loadedPath = loadedPath })

  local initOk = true
  if type(addon.init) == "function" then
    local central = M.getCentralConfig()
    local t0 = nowMs()
    local ok2, err2 = xpcall(function()
      return addon.init(entry, central)
    end, tb)
    local dt = math.max(0, (nowMs() - t0))
    if not ok2 then
      initOk = false
      safePrint(string.format("[GoL][Addons] init FAIL: %s (%s)", tostring(name), tostring(err2)))
      auditEvent(name, "init", false, err2, { initMs = dt, loaded = false })
    else
      auditEvent(name, "init", true, nil, { initMs = dt })
    end
  else
    auditEvent(name, "init", true, nil, { initMs = 0 })
  end

  if not initOk then
    return
  end

  M._loaded[name] = addon
  if a then
    a.loaded = true
    a.loadedAtMs = nowMs()
  end
  safePrint(string.format("[GoL][Addons] loaded: %s", tostring(name)))
end

function M.isLoaded(name)
  return type(name) == "string" and name ~= "" and (M._loaded and M._loaded[name] ~= nil) or false
end

local function getAddonEntry(name)
  local cfg = M.getCentralConfig()
  if type(cfg.addons) ~= "table" then return nil, cfg end
  return cfg.addons[name], cfg
end

-- Enable a single addon without restarting others.
-- Respects central config overlay (gift_of_life_state.lua) and does NOT purge widgets.
function M.enable(name)
  if type(name) ~= "string" or name == "" then return false, "bad name" end
  if M.isLoaded(name) then
    auditEvent(name, "enable", true, nil, { loaded = true })
    return true, "already loaded"
  end

  local entry, cfg = getAddonEntry(name)
  if type(cfg) == "table" and cfg.addonsEnabled == false then
    auditEvent(name, "enable", false, "addons disabled", { enabledInCfg = (type(entry) == "table" and entry.enabled == true) })
    return false, "addons disabled"
  end
  if type(entry) ~= "table" or entry.enabled ~= true then
    auditEvent(name, "enable", false, "not enabled in config", { enabledInCfg = false })
    return false, "not enabled in config"
  end

  loadOne(name, entry)
  local ok = M.isLoaded(name)
  auditEvent(name, "enable", ok, ok and nil or "enable failed", { enabledInCfg = true, loaded = ok })
  return ok, "enabled"
end


-- Disable a single addon without touching others.
function M.disable(name)
  if type(name) ~= "string" or name == "" then return false, "bad name" end
  local addon = M._loaded and M._loaded[name] or nil
  if not addon then
    auditEvent(name, "disable", true, nil, { loaded = false })
    return true, "already off"
  end

  if type(addon) == "table" and type(addon.shutdown) == "function" then
    local ok, err = xpcall(function() return addon.shutdown() end, tb)
    auditEvent(name, "shutdown", ok, err, { loaded = false })
  else
    auditEvent(name, "shutdown", true, nil, { loaded = false })
  end

  M._loaded[name] = nil
  local a = auditEnsure(name)
  if a then a.loaded = false end
  safePrint(string.format("[GoL][Addons] disabled: %s", tostring(name)))
  return true, "disabled"
end


-- Convenience: re-init a single addon if enabled.
function M.reloadOne(name)
  pcall(M.disable, name)
  return M.enable(name)
end

function M.loadEnabled()
  if M._loadToken ~= LOAD_TOKEN then return end

  local cfg = M.getCentralConfig()
  if cfg.addonsEnabled == false then
    safePrint("[GoL][Addons] addonsEnabled = false (skipping)")
    return
  end

  local addons = cfg.addons or {}
  local order = getAddonOrder(addons)

  for _, name in ipairs(order) do
    local entry = addons[name]
    loadOne(name, entry)
  end
end


function M.reloadEnabled(opts)
  -- Reload enabled addons. For UI toggles we often want a "soft" reload
  -- without running LeakGuard purge.
  if type(M.shutdownAll) == "function" then
    pcall(M.shutdownAll, opts)
  end
  if type(M.loadEnabled) == "function" then
    pcall(M.loadEnabled)
  end
end

function M.shutdownAll(opts)
  M._loadToken = (tonumber(M._loadToken) or 0) + 1

  for name, addon in pairs(M._loaded or {}) do
    if type(addon) == "table" and type(addon.shutdown) == "function" then
      local ok, err = xpcall(function() return addon.shutdown() end, tb)
      auditEvent(name, "shutdownAll", ok, err, { loaded = false })
    else
      auditEvent(name, "shutdownAll", true, nil, { loaded = false })
    end
    M._loaded[name] = nil
    local a = auditEnsure(name)
    if a then a.loaded = false end
  end

  if wantPurge(opts) then
    if _G.GoLLeakGuard and type(_G.GoLLeakGuard.purge) == "function" then
      pcall(_G.GoLLeakGuard.purge)
    end
    safePrint("[GoL][Addons] shutdownAll")
  else
    safePrint("[GoL][Addons] shutdownAll (soft)")
  end
end

return M
