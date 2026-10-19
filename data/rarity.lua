-- ScavTracker / data / rarity
--
-- Maps component TYPE names (parsed name without the trailing "components"
-- word, e.g. "Enhancing", "Noxious") to a numeric rarity rank for sorting.
-- Higher rank = rarer.
--   rank 2 = rare
--   rank 1 = uncommon (default for anything not in the rare set)
-- Lists sourced from the RuneScape Wiki's Scavenging material tables.

local Rarity = {}

Rarity.RARE     = 2
Rarity.UNCOMMON = 1

-- Component type names that are RARE (lowercased for case-insensitive lookup).
-- Everything not listed here is treated as uncommon.
local RARE_SET = {
    ["armadyl"]      = true,
    ["ascended"]     = true,
    ["avernic"]      = true,
    ["bandos"]       = true,
    ["brassican"]    = true,
    ["clockwork"]    = true,
    ["corporeal"]    = true,
    ["culinary"]     = true,
    ["cywir"]        = true,
    ["dragonfire"]   = true,
    ["ecliptic"]     = true,
    ["explosive"]    = true,
    ["faceted"]      = true,
    ["fortunate"]    = true,
    ["fungal"]       = true,
    ["harnessed"]    = true,
    ["ilujankan"]    = true,
    ["knightly"]     = true,
    ["manufactured"] = true,
    ["noxious"]      = true,
    ["oceanic"]      = true,
    ["pestiferous"]  = true,
    ["resilient"]    = true,
    ["rumbling"]     = true,
    ["saradomin"]    = true,
    ["seren"]        = true,
    ["shadow"]       = true,
    ["shifting"]     = true,
    ["silent"]       = true,
    ["third-age"]    = true,
    ["undead"]       = true,
    ["zamorak"]      = true,
    ["zaros"]        = true,
}

-- Return the rarity rank for a component type name (higher = rarer).
function Rarity.Rank(name)
    if name == nil then return Rarity.UNCOMMON end
    if RARE_SET[string.lower(name)] then
        return Rarity.RARE
    end
    return Rarity.UNCOMMON
end

return Rarity
