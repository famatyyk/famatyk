-- addons/leak_guard.lua
-- Gift of Life Leak Guard (UI cleanup helper).
-- Goal: reduce "widget was not explicitly destroyed" warnings during reloads.
-- Safe: only targets GiftOfLife-related widgets by id/prefix. ASCII comments only.

_G.GoLLeakGuard = _G.GoLLeakGuard or {}
local L = _G.GoLLeakGuard

-- forward decl (used by purgeTracked)
local destroyWidget

-- Optional weak registry of widgets created by GoL.
-- Weak values so tracking does not keep widgets alive by itself.
L._tracked = L._tracked or setmetatable({}, { __mode = "v" })

function L.track(w)
  if not w then return end
  local t = L._tracked
  if type(t) ~= "table" then return end
  -- Deduplicate (pairs works with weak tables and holes).
  for _, v in pairs(t) do
    if v == w then return end
  end
  t[#t + 1] = w
end

local function purgeTracked()
  local t = L._tracked
  if type(t) ~= "table" then return end
  for k, v in pairs(t) do
    if v then destroyWidget(v) end
    t[k] = nil
  end
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

local function loadCentralConfig()
  local ok, cfg = tryDofile({
    "config.lua",
    "gift_of_life/config.lua",
    "modules/gift_of_life/config.lua",
  })
  if ok and type(cfg) == "table" then return cfg end
  return {}
end

local function getLeakCfg()
  local cfg = loadCentralConfig()
  local lc = cfg.leakGuard
  if type(lc) ~= "table" then lc = {} end

  -- Defaults (safe)
  local out = {
    enabled = (lc.enabled ~= false),
    aggressive = (lc.aggressive == true),
    cleanComboPopup = (lc.cleanComboPopup ~= false),
    ids = (type(lc.ids) == "table") and lc.ids or { "giftOfLifeWindow", "GiftOfLifeHud", "GiftOfLifeStatus", "GoLDevEditor_hotkeys", "GoLDevEditor_macros", "GoLDevEditor_scripts", "GoLDevCatalog" },
    prefixes = (type(lc.prefixes) == "table") and lc.prefixes or { "GiftOfLife", "giftOfLife", "GoLDev" },
  }

  return out
end

local function getRoots()
  local roots = {}
  local rootPanel = nil
  -- Prefer game interface root panel if available (some forks attach module windows there).
  if modules and modules.game_interface and modules.game_interface.getRootPanel then
    local ok, r = pcall(modules.game_interface.getRootPanel)
    if ok and r then rootPanel = r end
  end
  if rootPanel then roots[#roots + 1] = rootPanel end

  local rootWidget = g_ui and g_ui.getRootWidget and g_ui.getRootWidget() or nil
  if rootWidget and rootWidget ~= rootPanel then roots[#roots + 1] = rootWidget end

  return roots
end

destroyWidget = function(w)
  if not w then return false end
  if type(w.isDestroyed) == "function" then
    local ok, dead = pcall(w.isDestroyed, w)
    if ok and dead then return false end
  end

  pcall(function()
    if type(w.destroyChildren) == "function" then w:destroyChildren() end
  end)
  pcall(function()
    if type(w.destroy) == "function" then w:destroy() end
  end)
  return true
end

local function getId(w)
  if not w or type(w.getId) ~= "function" then return nil end
  local ok, id = pcall(w.getId, w)
  if ok and type(id) == "string" and id ~= "" then return id end
  return nil
end

local function getChildren(w)
  if not w or type(w.getChildren) ~= "function" then return nil end
  local ok, kids = pcall(w.getChildren, w)
  if ok and type(kids) == "table" then return kids end
  return nil
end

local function startsWith(s, pref)
  return type(s) == "string" and type(pref) == "string" and s:sub(1, #pref) == pref
end

function L.purge()
  local lc = getLeakCfg()
  if not lc.enabled then return end

  local roots = getRoots()
  if type(roots) ~= "table" or #roots == 0 then return end

  -- 0) Destroy tracked widgets (best-effort).
  pcall(purgeTracked)

  -- 1) Safe pass on all roots (ids + combobox popup).
  for _, root in ipairs(roots) do
    -- 1) Target known top-level widgets by id
    if root and type(root.recursiveGetChildById) == "function" then
      for _, id in ipairs(lc.ids or {}) do
        if type(id) == "string" and id ~= "" then
          local ok, w = pcall(function() return root:recursiveGetChildById(id) end)
          if ok then destroyWidget(w) end
        end
      end
    end
    -- 1.5) ComboBox popup cleanup disabled (some forks throw uncatchable C++ errors here).
  end

  -- 2) Optional aggressive pass: destroy any widget whose id starts with our prefixes.
  if not lc.aggressive then
    safePrint("[GoL][LeakGuard] purge (safe)")
    return
  end

  local visited = {}
  local function scan(w, depth)
    if not w or depth > 300 then return end
    if visited[w] then return end
    visited[w] = true

    local id = getId(w)
    if id then
      for _, pref in ipairs(lc.prefixes or {}) do
        if startsWith(id, pref) then
          destroyWidget(w)
          return
        end
      end
    end

    local kids = getChildren(w)
    if kids then
      for _, c in ipairs(kids) do
        scan(c, depth + 1)
      end
    end
  end

  for _, root in ipairs(roots) do
    scan(root, 0)
  end
  safePrint("[GoL][LeakGuard] purge (aggressive)")
end

return L
