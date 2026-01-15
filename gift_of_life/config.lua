-- config.lua
-- Gift of Life central configuration (core + addons).
-- Edit THIS file only. Keep comments ASCII-only.

return {
  -- Select a profile name from the "profiles" table below.
  activeProfile = "default",

  -- Dev tools (Dbg/Catalog/Editor). Disable to keep runtime-only.
  devTools = { enabled = true },

  -- Base settings (applies to all profiles).
  base = {
    -- === Master toggles (initial state) ===
      healEnabled = true,
      manaEnabled = true,

      -- === Mana potion IDs (adjust to your server) ===
      -- You can put multiple IDs; the script will try them in order.
      manaPotionIds = { 238, 237, 268 },

      -- === Mana thresholds (choose ONE mode) ===
      -- Percent mode:
      manaStartPct = 35,
      manaStopPct  = 80,

      -- Absolute mode (optional, overrides percent if set and client can read mana):
      manaStartMana = nil, -- e.g. 500
      manaStopMana  = nil, -- e.g. 2500

      -- Optional randomized thresholds per drink cycle (human-ish):
      -- Percent ranges:
      manaStartPctMin = nil,
      manaStartPctMax = nil,
      manaStopPctMin  = nil,
      manaStopPctMax  = nil,

      -- Absolute ranges:
      manaStartManaMin = nil,
      manaStartManaMax = nil,
      manaStopManaMin  = nil,
      manaStopManaMax  = nil,

      -- Additional profiles (picked randomly per cycle). Use percent OR absolute.
      manaRanges = nil,

      -- === Healing thresholds (HP percent) ===
      hpExuraPct     = 88,
      hpExuraGranPct = 70,
      hpExuraVitaPct = 52,

      -- Spells to cast
      spellExura     = "exura",
      spellExuraGran = "exura gran",
      spellExuraVita = "exura vita",

      -- === Timers ===
      tickMs           = 120,
      spellCooldownMs  = 850,
      potionCooldownMs = 900,

      -- Optional jitter on potion cooldown (table {minMs, maxMs})
      -- Example: potionCooldownJitterMs = { -150, 250 }
      potionCooldownJitterMs = nil,

      -- If you have 0 potions, don't spam attempts (ms)
      noPotRetryMs = 7000,
      noPotLogThrottleMs = 10000,

      -- Limit potion debug spam (ms)
      potionLogThrottleMs = 2500,

      -- === Loot ===
      -- You still open the corpse/container manually; the script moves items out.
      lootEnabled = false,

      loot = {
        -- "list" = loot only itemIds; "all" = loot everything except ignoreIds
        mode = "list",
        itemIds   = { },   -- IDs to loot (mode=list)
        ignoreIds = { },   -- never loot (mode=all/list)

        -- Route rules
        goldIds  = { 3031, 3035, 3043 }, -- gold / platinum / crystal (adjust if your server differs)
        stackIds = { },                  -- IDs to route to stack BP (optional)

        -- Destination containers by NTH open container (1 = first opened container)
        mainBpNth  = 1,
        lootBpNth  = 2,
        stackBpNth = 3,

        -- Source container selection:
        -- "lastNonBp" = newest opened container that is NOT a backpack/bag (heuristic)
        -- "nth" = use sourceNth below
        sourcePolicy = "lastNonBp",
        sourceNth = 4,

        -- Name filters used by lastNonBp heuristic (lowercase substring match)
        skipNameContains = { "backpack", "bag", "pouch", "quiver" },

        -- Throttling (avoid spam / cooldown issues)
        moveCooldownMs = 120,
        maxMovesPerTick = 1,

        -- Low capacity safety (0 = disabled)
        minCap = 150,
        -- "skip" = skip looting when low cap; "pauseLoot" = auto-disable loot until cap ok
        lowCapBehavior = "skip",
        -- If destination is full, try opening the first container-item inside it
        openNextOnFull = true,
        openNextCooldownMs = 800,
        -- If true, try to stack gold/stackIds into existing stacks in destination (less slot waste)
        stackIntoExisting = true,
      
        -- Hardening: keep source container pinned for a short time (prevents corpse flapping)
        sourcePinMs = 6000,
        -- Hardening: wait after auto-opening next BP before moving again
        openWaitMs = 650,

        -- Server-specific stack sizes
        goldStackMax = 200,
        stackMax = 100,

        -- QoL: coin change (uses coin stack). On this server stacks and change threshold are 200.
        coinChangeEnabled = true,
        coinChangeThreshold = 200,
        coinChangeCooldownMs = 800,
        coinChangeMaxUsesPerTick = 1,

        -- QoL: stack sorter (merges partial stacks inside backpacks to save slots)
        sorterEnabled = true,
        sorterCooldownMs = 600,
        sorterMaxMovesPerTick = 2,
},

      -- Debug prints
      debug = false,

      -- If true, allow plain g_game.use(item) as a last resort (usually keep false)
      allowDirectUse = false,

      -- HUD shows current HP/MP values near top-left
      hudEnabled = true,
      hudUpdateMs = 250,
  },

  -- Profile overrides (merged over "base").
  -- Put ONLY overrides here.
  profiles = {
    default = {},
    -- pvp = {
    --   hpExuraPct = 92,
    --   hudUpdateMs = 150,
    -- },
  },

  -- === Addons (everything new goes here, NOT into gift_of_life.lua) ===
  -- Spell rotation addon config (addons/autospell_rotation.lua)
  spellRotation = {
    enabled = false,

    -- Loop timing
    tickMs = 120,

    -- General cooldowns (ms)
    spellCooldownMs = 900,
    runeCooldownMs  = 900,

    -- Targeting / scanning
    requireTarget = false, -- if API supports it
    multifloor = false,
    castRange = 7,    -- tiles around player to consider for rune target tiles
    scanRange = 8,    -- monsters scan range
    requireSight = false, -- if g_map.isSightClear exists

    -- Hotkey to toggle rotation ON/OFF
    hotkeyToggle = "Ctrl+Shift+R",

    -- AoE runes: choose BEST tile (max monsters inside aoeRadius)
    aoeDefaultRadius = 1, -- chebyshev radius; 1 => 3x3, 2 => 5x5
    runes = {
      enabled = true,
      -- Add your AoE runes here:
      list = {
        -- Example:
                -- Preset (user provided IDs):
        { itemId = 3202, shape = "big37", minTargets = 3 }, -- Thunderstorm Rune
        { itemId = 3191, shape = "big37", minTargets = 3 }, -- Great Fireball Rune
        { itemId = 3161, shape = "big37", minTargets = 3 }, -- Avalanche Rune

        -- Example (radius-based):
        -- { itemId = 3191, aoeRadius = 1, minTargets = 3, requireSight = false },
      },
    },

    -- Spells: priority list (first match gets cast)
    spells = {
      -- Example:
      -- { text = "exori", minManaPct = 30, minTargets = 2, cooldownMs = 1200 },
      -- { hotkey = "F1", maxHpPct = 60, cooldownMs = 900 }, -- send key instead of talk
    },
  },

  -- Leak guard: cleans orphaned widgets during reloads (reduces DEBUG warnings).
  leakGuard = {
    enabled = true,
    -- If true: also destroys any widget whose id starts with prefixes below.
    -- Keep false unless you still see warnings after reloads.
    aggressive = false,
    -- Known top-level GoL widgets to destroy on reload:
    ids = { "giftOfLifeWindow", "GiftOfLifeHud", "GiftOfLifeStatus", "giftOfLifeRotationEditorWindow" },
    prefixes = { "GiftOfLife", "giftOfLife" },
  },

  addonsEnabled = true,

  -- Each addon is a table:
  --   enabled = true/false
  --   file    = optional lua path (defaults to addons/<name>.lua)
  --   ...any custom settings for that addon...
  addons = {
    -- Deterministic load order (optional). If empty, loads in arbitrary order.
    _order = {-- "example_template",
      "autospell_rotation",},

    -- Example addon entry (kept disabled):
    example_template = {
      enabled = false,
      file = "addons/example_template.lua",
    },

    -- Top 5 automations (enabled=false by default)
    panic_guard = {
      enabled = false,
      file = "addons/panic_guard.lua",
      cfg = {
        enabled = true,
        tickMs = 250,
        pauseMs = 3500,
        scanRange = 9,
        lowHpPct = 35,
        detectPlayers = true,
      },
    },

    smart_target = {
      enabled = false,
      file = "addons/smart_target.lua",
      cfg = {
        enabled = true,
        tickMs = 250,
        range = 8,
        chaseMode = 1,
        fightMode = 2,
      },
    },

    combat_modes = {
      enabled = false,
      file = "addons/combat_modes.lua",
      cfg = {
        enabled = true,
        tickMs = 350,
        safeHpPct = 60,
        fightModeHigh = 2,
        fightModeLow = 1,
        chaseOn = 1,
        chaseOff = 0,
        rateLimitMs = 600,
      },
    },

    smart_kite = {
      enabled = false,
      file = "addons/smart_kite.lua",
      cfg = {
        enabled = true,
        tickMs = 120,
        hpBelow = 45,
        stepCooldownMs = 350,
        scanRange = 2,
      },
    },

    autospell_rotation = {
      enabled = false,
      file = "addons/autospell_rotation.lua",
      cfg = {
        enabled = true,

        -- Basic behavior
        tickMs = 150,
        requireTarget = true,

        -- AoE runes (your IDs)
        runes = {
          thunderstorm = 3202,
          gfb = 3191,
          ava = 3161,
        },

        -- Default spell/rune sequence (can be edited)
        rotation = {
          -- Example: { type="rune", key="gfb", minMana=0, minMonsters=3, range=7 }
        },
      },
    },

  },
}
