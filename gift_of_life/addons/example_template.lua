-- addons/example_template.lua
-- Example addon template for Gift of Life.
-- This file must RETURN a table with optional init/shutdown.

local A = {}
local _enabled = false

function A.init(entry, centralCfg)
  _enabled = true
  if print then print("[GoL][ExampleAddon] init") end

  -- entry: addons.example_template table from config.lua
  -- centralCfg: full central config.lua (base/profiles/addons)

  -- Put your addon logic here (create widgets, bind hotkeys, schedule events, etc).
  -- IMPORTANT: keep it reload-safe and implement shutdown().
end

function A.shutdown()
  if not _enabled then return end
  _enabled = false
  if print then print("[GoL][ExampleAddon] shutdown") end

  -- Cleanup: remove events, destroy widgets, unbind hotkeys.
end

return A
