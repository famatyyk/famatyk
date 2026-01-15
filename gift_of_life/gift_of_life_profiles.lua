-- gift_of_life_profiles.lua
-- Built-in profile templates (spell rotation presets).
-- Safe defaults: rotation is enabled, but lists are empty until you configure them.

local function makeRotationBase()
  return {
    -- Only affects the autospell_rotation addon.
    spellRotation = {
      enabled = true,

      -- Loop timing
      tickMs = 120,

      -- Cooldowns (ms)
      spellCooldownMs = 900,
      runeCooldownMs  = 900,

      -- Targeting / scanning
      requireTarget = false,
      multifloor = false,
      castRange = 7,
      scanRange = 8,
      requireSight = false,

      -- Hotkey to toggle rotation ON/OFF (addon-side toggle)
      hotkeyToggle = "Ctrl+Shift+R",

      -- ACTION LISTS (empty by default; edit later)
      -- spells = { { text="exori", cooldownMs=1200, minManaPct=20, minTargets=1 }, ... }
      spells = {},

      -- runes = { enabled=true, list={ { itemId=3161, minTargets=3, shape={shape="big37"} }, ... } }
      runes = {
        enabled = false,
        list = {},
      },
    },
  }
end

local profiles = {}

-- Generic
profiles["rotation_blank"] = makeRotationBase()

-- Vocations (templates)
profiles["rotation_ek_single"] = makeRotationBase()
profiles["rotation_ek_aoe"]    = makeRotationBase()

profiles["rotation_rp_single"] = makeRotationBase()
profiles["rotation_rp_aoe"]    = makeRotationBase()

profiles["rotation_ms_single"] = makeRotationBase()
profiles["rotation_ms_aoe"]    = makeRotationBase()

profiles["rotation_ed_support"] = makeRotationBase()

-- Specialized
profiles["rotation_runes_only"] = (function()
  local p = makeRotationBase()
  p.spellRotation.spells = {}
  p.spellRotation.runes.enabled = true
  return p
end)()

profiles["rotation_safe_min"] = (function()
  local p = makeRotationBase()
  -- more conservative scan range (less client work)
  p.spellRotation.scanRange = 6
  p.spellRotation.castRange = 6
  return p
end)()

return profiles
