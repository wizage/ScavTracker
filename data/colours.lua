-- ScavTracker / data / colours
--
-- Global (not per-account) setting for colouring component name text by
-- rarity. Stores an enable flag plus a rare and an uncommon colour as hex
-- strings, persisted under fixed keys. Defaults are the game's own colours
-- (placeholders until confirmed from the chat <col=...> logs).

local Colours = {}

-- Fixed persistence keys (global across accounts).
local KEY_ENABLED   = "scav_colourEnabled"
local KEY_RARE      = "scav_colourRare"
local KEY_UNCOMMON  = "scav_colourUncommon"

-- Default hex colours (no leading #). Placeholders: orange uncommon (matches
-- the scav proc's <col=ffa500>) and red rare - swap once the real rare hex is
-- captured from chat.
local DEFAULT_RARE     = "ff0000"
local DEFAULT_UNCOMMON = "ffa500"

Colours.enabled      = false
Colours.rareHex      = DEFAULT_RARE
Colours.uncommonHex  = DEFAULT_UNCOMMON

-- Normalise a hex string: strip #, lowercase, keep only 6 hex digits.
-- Returns a valid 6-digit hex or nil.
local function normHex(s)
    if type(s) ~= "string" then return nil end
    s = string.gsub(s, "^#", "")
    s = string.lower(s)
    if string.match(s, "^%x%x%x%x%x%x$") then return s end
    return nil
end
Colours.NormHex = normHex

-- Convert a hex string (RRGGBB) to a Vector4 for component.colour, or nil.
function Colours.HexToVector4(hex)
    local h = normHex(hex)
    if h == nil then return nil end
    local r = tonumber(h:sub(1, 2), 16) / 255
    local g = tonumber(h:sub(3, 4), 16) / 255
    local b = tonumber(h:sub(5, 6), 16) / 255
    return Vector4.new(r, g, b, 1.0)
end

function Colours:Load()
    local okE, en = pcall(function() return PersistentDB:GetBool(KEY_ENABLED) end)
    self.enabled = (okE and en == true)

    local okR, r = pcall(function() return PersistentDB:GetString(KEY_RARE) end)
    self.rareHex = (okR and normHex(r)) or DEFAULT_RARE

    local okU, u = pcall(function() return PersistentDB:GetString(KEY_UNCOMMON) end)
    self.uncommonHex = (okU and normHex(u)) or DEFAULT_UNCOMMON
end

function Colours:SetEnabled(on)
    self.enabled = on == true
    pcall(function() PersistentDB:SetBool(KEY_ENABLED, self.enabled) end)
end

function Colours:IsEnabled() return self.enabled end

-- Set the rare/uncommon colour from a hex string; ignores invalid input.
function Colours:SetRare(hex)
    local h = normHex(hex)
    if h then self.rareHex = h; pcall(function() PersistentDB:SetString(KEY_RARE, h) end) end
end

function Colours:SetUncommon(hex)
    local h = normHex(hex)
    if h then self.uncommonHex = h; pcall(function() PersistentDB:SetString(KEY_UNCOMMON, h) end) end
end

function Colours:GetRareHex()     return self.rareHex end
function Colours:GetUncommonHex() return self.uncommonHex end

-- Vector4 for a rarity rank (2 = rare, else uncommon), or nil if disabled.
function Colours:ForRarity(rank)
    if not self.enabled then return nil end
    local hex = (rank == 2) and self.rareHex or self.uncommonHex
    return Colours.HexToVector4(hex)
end

return Colours
