_G.GoL_ReloadSeq = (tonumber(_G.GoL_ReloadSeq) or 0) + 1
local _GOL_RELOAD_SEQ = _G.GoL_ReloadSeq

-- init.lua
-- Gift of Life module bootstrap (modular).
-- English comments only.

-- Preload LeakGuard (if present) and purge stale widgets by id.
-- This runs even if a previous load crashed before defining shutdown().
local function _gol_tryDofileOne(path)
  if type(path) ~= "string" or path == "" then return false end
  local ok, err = pcall(function() dofile(path) end)
  return ok
end

local function _gol_prePurge()
  -- Try to load leak guard from common paths (module-relative and absolute).
  _gol_tryDofileOne("addons/leak_guard.lua")
  _gol_tryDofileOne("gift_of_life/addons/leak_guard.lua")
  _gol_tryDofileOne("modules/gift_of_life/addons/leak_guard.lua")

  -- CLEANUP3: LeakGuard++ (track&destroy + event purge)
  _G.GoL = type(_G.GoL) == "table" and _G.GoL or {}
  _gol_tryDofileOne("leakguard_pp.lua")
  _gol_tryDofileOne("gift_of_life/leakguard_pp.lua")
  _gol_tryDofileOne("modules/gift_of_life/leakguard_pp.lua")

  if _G.GoLLeakGuard and type(_G.GoLLeakGuard.purge) == "function" then
    pcall(_G.GoLLeakGuard.purge)
  end
  if _G.GoL and _G.GoL.LeakGuardPP and type(_G.GoL.LeakGuardPP.purgeAll) == "function" then
    pcall(_G.GoL.LeakGuardPP.purgeAll)
    return
  end

  -- Fallback (no leak guard): destroy known widgets directly.
  local root = nil
  if modules and modules.game_interface and modules.game_interface.getRootPanel then
    local ok, r = pcall(modules.game_interface.getRootPanel)
    if ok then root = r end
  end
  if not root and g_ui and g_ui.getRootWidget then root = g_ui.getRootWidget() end
  if not root or type(root.recursiveGetChildById) ~= "function" then return end

  local function kill(id)
    local ok, w = pcall(function() return root:recursiveGetChildById(id) end)
    if ok and w and type(w.destroy) == "function" then pcall(w.destroy, w) end
  end
  kill("giftOfLifeWindow")
  kill("GiftOfLifeHud")
  kill("GiftOfLifeStatus")
end

pcall(function() if _G.GoLDev and type(_G.GoLDev.shutdown) == "function" then _G.GoLDev.shutdown({ purge = true }) end end)

pcall(_gol_prePurge)

-- Ensure modules/search paths are available when running via dofile().
local function _gol_addSearchPaths()
  if not g_resources then return end
  if type(g_resources.getWorkDir) ~= 'function' then return end
  if type(g_resources.addSearchPath) ~= 'function' then return end
  local wd = g_resources.getWorkDir()
  -- Some forks report VFS root ('/') here. In that case, do NOT try to build OS paths.
  if type(wd) ~= 'string' or wd == '' or wd == '/' or wd == './' then return end
  if wd:sub(-1) ~= '/' and wd:sub(-1) ~= '\\' then wd = wd .. '/' end
  local candidates = {
    wd .. 'modules',
    wd .. 'modules/gift_of_life',
    wd .. 'mods',
  }
  for _, sp in ipairs(candidates) do
    pcall(function() g_resources.addSearchPath(sp, true) end)
  end
end

pcall(_gol_addSearchPaths)

-- Reload-safety:
-- 1) shutdown addons first (if present)
-- 2) shutdown core
if _G.GoLAddons and type(_G.GoLAddons.shutdownAll) == "function" then
  pcall(_G.GoLAddons.shutdownAll, { purge = false })
end

if _G.GiftOfLife and type(_G.GiftOfLife.shutdown) == "function" then
  pcall(_G.GiftOfLife.shutdown)
end

local function tryDofile(paths)
  local lastErr = nil
  for _, p in ipairs(paths) do
    local ok, ret = pcall(dofile, p)
    if ok then
      print(string.format("[GiftOfLife] init loaded: %s", p))
      return true, ret, p
    end
    lastErr = ret
    print(string.format("[GiftOfLife] init dofile failed: %s (%s)", p, tostring(ret)))
  end
  print(string.format("[GiftOfLife] init FAILED (last error: %s)", tostring(lastErr)))
  return false, nil, nil
end

-- 1) Load core (unchanged).
local ok = tryDofile({
  "gift_of_life.lua",
  "gift_of_life/gift_of_life.lua",
  "modules/gift_of_life/gift_of_life.lua",
})

print("[GiftOfLife] boot: v12 PRO (PRE8) - AAH PRO (filter/sort/expand) + Dev Catalog v2")

-- 2) Load addon manager and enabled addons.
if ok then
  local okA, addonMgr = tryDofile({
    "addons/addons.lua",
    "gift_of_life/addons/addons.lua",
    "modules/gift_of_life/addons/addons.lua",
  })

  if okA and _G.GoLAddons and type(_G.GoLAddons.loadEnabled) == "function" then
    pcall(_G.GoLAddons.loadEnabled)
  end
end

-- 3) Load Dev Tools (Dbg-only; manual reload)
local function _golDevEnabled()
  -- Read config.lua early to decide whether to load DEV modules.
  local paths = {
    "config.lua",
    "gift_of_life/config.lua",
    "modules/gift_of_life/config.lua",
  }
  for _, p in ipairs(paths) do
    local okC, cfg = pcall(dofile, p)
    if okC and type(cfg) == "table" then
      if type(cfg.devTools) == "table" and cfg.devTools.enabled == false then
        return false
      end
      return true
    end
  end
  return true
end

if ok and _golDevEnabled() then
  local okD = tryDofile({
    "dev/ingame_editor.lua",
    "gift_of_life/dev/ingame_editor.lua",
    "modules/gift_of_life/dev/ingame_editor.lua",
  })
  if okD and _G.GoLDev and type(_G.GoLDev.init) == "function" then
    pcall(_G.GoLDev.init)
  end
elseif ok then
  print("[GoL][Dev] disabled by config (devTools.enabled=false)")
end

-- Boot UI + runtime (bind buttons, hooks, hotkeys, telemetry) AFTER all modules loaded
if ok and _G.GiftOfLife and type(_G.GiftOfLife.boot) == "function" then
  pcall(_G.GiftOfLife.boot)
end
