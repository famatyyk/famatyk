-- leakguard_pp.lua
-- GoL LeakGuard++: SAFE purge without iterating stale widget userdata (prevents C++ fatal on __index).
-- ASCII-only.

_G.GoL = type(_G.GoL) == "table" and _G.GoL or {}
local GoL = _G.GoL

GoL.LeakGuardPP = GoL.LeakGuardPP or {}
local LG = GoL.LeakGuardPP

LG._events     = LG._events or {}
LG._trackedIds = LG._trackedIds or {}   -- id -> label
LG._idSeq      = LG._idSeq or 0

LG._knownIds = LG._knownIds or {
  -- Main
  "giftOfLifeWindow",
  "giftOfLifeProfilePicker",
  "giftOfLifeRotationEditorWindow",
  -- Dev
  "GoLDevCatalog",
  "GoLDevEditor_hotkeys",
  "GoLDevEditor_macros",
  "GoLDevEditor_scripts",
}

local function _root()
  return (g_ui and g_ui.getRootWidget and g_ui.getRootWidget()) or nil
end

local function _rootPanel()
  local gi = modules and modules.game_interface
  if gi and gi.getRootPanel then
    local ok, rp = pcall(gi.getRootPanel)
    if ok and rp then return rp end
  end
  return _root()
end

local function _ensureId(w)
  -- NOTE: w is assumed alive at the time of tracking.
  local ok, id = pcall(function() return w:getId() end)
  if ok and type(id) == "string" and id ~= "" then return id end

  LG._idSeq = (LG._idSeq or 0) + 1
  local newId = "GoLTracked_" .. tostring(LG._idSeq)
  pcall(function() w:setId(newId) end)
  return newId
end

local function _destroyWidgetSafe(w)
  -- IMPORTANT: only call on widgets that are currently reachable (found via root by id).
  if not w then return false end
  pcall(function() w:hide() end)
  pcall(function() if w.destroyChildren then w:destroyChildren() end end)
  pcall(function() w:destroy() end)
  return true
end

function LG.trackWidget(w, label)
  if not w then return w end
  local id = _ensureId(w)
  if id then
    LG._trackedIds[id] = tostring(label or "tracked")
  end
  return w
end

function LG.destroyById(id, why)
  if not id or id == "" then return false end
  local parent = _rootPanel()
  if not parent then return false end
  local w = parent:recursiveGetChildById(id)
  if not w then
    -- try root as fallback
    local r = _root()
    if r and r ~= parent then w = r:recursiveGetChildById(id) end
  end
  if w then
    _destroyWidgetSafe(w)
  end
  -- Always drop id from registry (even if widget was already gone).
  LG._trackedIds[id] = nil
  return true
end

function LG.destroyWidget(w, why)
  -- Best-effort for immediate callers (do NOT rely on this during purge).
  if not w then return false end
  local ok, id = pcall(function() return w:getId() end)
  if ok and type(id) == "string" and id ~= "" then
    return LG.destroyById(id, why)
  end
  -- No id: attempt direct destroy (can still be unsafe if userdata is stale, but this is only for live widgets).
  _destroyWidgetSafe(w)
  return true
end

function LG.trackEvent(ev, label)
  if not ev then return ev end
  table.insert(LG._events, { ev = ev, label = tostring(label or "") })
  return ev
end

function LG.purgeEvents()
  if type(removeEvent) == "function" then
    for i = #LG._events, 1, -1 do
      local rec = LG._events[i]
      if rec and rec.ev then pcall(removeEvent, rec.ev) end
      LG._events[i] = nil
    end
  else
    LG._events = {}
  end
end

function LG.purgeKnownIds()
  for _, id in ipairs(LG._knownIds) do
    LG.destroyById(id, "purgeKnownIds")
  end
end

function LG.purgeTracked()
  -- SAFE: iterate ids, resolve fresh widgets from UI tree, then destroy.
  local ids = {}
  for id, _ in pairs(LG._trackedIds) do table.insert(ids, id) end
  for _, id in ipairs(ids) do
    LG.destroyById(id, "purgeTracked")
  end
end

function LG.purgeAll()
  LG.purgeEvents()
  LG.purgeKnownIds()
  LG.purgeTracked()
  if print then pcall(function() print("[GoL][LeakGuard++] purgeAll") end) end
end

return LG
