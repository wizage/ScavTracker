-- ScavTracker / data / stats
--
-- The database layer: three persisted counters of components gained, keyed by
-- component name, namespaced per-account by the player's tracking ID.
--
--   allTime       - history since install; never auto-reset.
--   session       - persists across reboots; cleared only by manual reset.
--   manualSession - "Trip": a second, independent manually-resettable counter.
--
-- Also tracks first/last-received order (for "order received" sorting) and the
-- persisted sort mode. All data goes through PersistentDB with a per-account
-- key prefix set via Stats:SetPrefix(trackingID).

local Rarity = require("data/rarity")

local Stats = {}

-- Sort mode constants (match the settings control options).
Stats.SORT_ORDER_RECEIVED  = 1  -- most recently received first
Stats.SORT_RARITY_COUNT    = 2  -- rarity desc, then count desc
Stats.SORT_RARITY_RECEIVED = 3  -- rarity desc, then recency
Stats.SORT_COUNT           = 4  -- count desc

-- PersistentDB key base names; prefixed per-account via keyFor().
local KEY_ALLTIME        = "allTime"
local KEY_SESSION        = "session"
local KEY_MANUAL_SESSION = "manualSession"
local KEY_ORDER          = "order"       -- component -> received sequence
local KEY_SORT_MODE      = "sortMode"    -- int, one of SORT_*

-- Per-account key prefix (shared "anon" bucket until a tracking ID is set).
local keyPrefix = "scav_anon_"
local nextSeq   = 1   -- next received-order sequence to assign

local function keyFor(base) return keyPrefix .. base end

-- In-memory state, loaded on Load() and written back on change.
Stats.allTime = {}
Stats.session = {}
Stats.manualSession = {}
Stats.order = {}
Stats.sortMode = Stats.SORT_RARITY_COUNT

-- Set the per-account key prefix from a tracking ID. Call before Load().
function Stats:SetPrefix(trackingID)
    keyPrefix = (trackingID == nil) and "scav_anon_"
        or ("scav_" .. tostring(trackingID) .. "_")
end

-- Expose the active prefix so other modules (e.g. UI) can namespace keys too.
function Stats:KeyPrefix() return keyPrefix end

local function loadTable(base)
    local ok, value = pcall(function() return PersistentDB:GetStructuredData(keyFor(base)) end)
    if ok and type(value) == "table" then return value end
    return {}
end

local function saveTable(base, tbl)
    pcall(function() PersistentDB:SetStructuredData(keyFor(base), tbl) end)
end

-- Load all counters + settings for the current account prefix.
function Stats:Load()
    self.allTime       = loadTable(KEY_ALLTIME)
    -- Session is per client-launch: it is NOT persisted, so it starts empty
    -- every time the plugin loads (i.e. each client launch / reload).
    self.session       = {}
    self.manualSession = loadTable(KEY_MANUAL_SESSION)
    self.order         = loadTable(KEY_ORDER)

    local ok, mode = pcall(function() return PersistentDB:GetInt(keyFor(KEY_SORT_MODE)) end)
    self.sortMode = (ok and type(mode) == "number") and mode or self.SORT_RARITY_COUNT

    -- Resume the received-order sequence past the highest stored value.
    nextSeq = 1
    for _, seq in pairs(self.order) do
        if type(seq) == "number" and seq >= nextSeq then nextSeq = seq + 1 end
    end

    -- Backfill order for components that have counts but no order entry
    -- (e.g. gained before order tracking existed), alphabetically.
    local missing = {}
    for name in pairs(self.allTime) do
        if self.order[name] == nil then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        table.sort(missing)
        for _, name in ipairs(missing) do
            self.order[name] = nextSeq
            nextSeq = nextSeq + 1
        end
        saveTable(KEY_ORDER, self.order)
    end
end

-- Sort mode accessors (persisted).
function Stats:GetSortMode() return self.sortMode or self.SORT_COUNT end

function Stats:SetSortMode(mode)
    self.sortMode = mode
    pcall(function() PersistentDB:SetInt(keyFor(KEY_SORT_MODE), mode) end)
end

-- Record a component gain across all three counters + received order.
-- Returns the updated allTime, session, manualSession totals for convenience.
function Stats:Add(component, amount)
    self.allTime[component]       = (self.allTime[component] or 0) + amount
    self.session[component]       = (self.session[component] or 0) + amount
    self.manualSession[component] = (self.manualSession[component] or 0) + amount

    -- Bump received order on EVERY proc so the latest sorts to the top.
    self.order[component] = nextSeq
    nextSeq = nextSeq + 1

    saveTable(KEY_ORDER, self.order)
    saveTable(KEY_ALLTIME, self.allTime)
    -- Session is in-memory only (resets each launch), so it is not saved.
    saveTable(KEY_MANUAL_SESSION, self.manualSession)

    return self.allTime[component], self.session[component], self.manualSession[component]
end

function Stats:ResetSession()
    self.session = {}   -- in-memory only; session is never persisted
end

function Stats:ResetManualSession()
    self.manualSession = {}
    saveTable(KEY_MANUAL_SESSION, self.manualSession)
end

local function sumTable(tbl)
    local total = 0
    for _, v in pairs(tbl) do total = total + v end
    return total
end

function Stats:TotalAllTime()      return sumTable(self.allTime) end
function Stats:TotalSession()       return sumTable(self.session) end
function Stats:TotalManualSession() return sumTable(self.manualSession) end

-- Counter table for a tab key: "session" | "trip" | "allTime".
function Stats:GetCounter(which)
    if which == "session" then return self.session end
    if which == "trip" then return self.manualSession end
    return self.allTime
end

-- Return { name, count, rarity, order } rows for a counter, sorted by the
-- current sort mode.
function Stats:GetSorted(which)
    local counter = self:GetCounter(which)
    local rows = {}
    for name, count in pairs(counter) do
        rows[#rows + 1] = {
            name   = name,
            count  = count,
            rarity = Rarity.Rank(name),
            order  = self.order[name] or 0,
        }
    end

    local mode = self:GetSortMode()
    local byName = function(a, b) return a.name < b.name end

    table.sort(rows, function(a, b)
        if mode == self.SORT_ORDER_RECEIVED then
            if a.order ~= b.order then return a.order > b.order end
            return byName(a, b)
        elseif mode == self.SORT_RARITY_COUNT then
            if a.rarity ~= b.rarity then return a.rarity > b.rarity end
            if a.count ~= b.count then return a.count > b.count end
            return byName(a, b)
        elseif mode == self.SORT_RARITY_RECEIVED then
            if a.rarity ~= b.rarity then return a.rarity > b.rarity end
            if a.order ~= b.order then return a.order > b.order end
            return byName(a, b)
        else -- SORT_COUNT
            if a.count ~= b.count then return a.count > b.count end
            return byName(a, b)
        end
    end)

    return rows
end

return Stats
