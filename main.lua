-- ScavTracker - entry point / orchestrator
--
-- Thin wiring layer. The actual work lives in folders:
--   data/   - persistence + counters (stats) and rarity data
--   chat/   - chat reader that detects component-gain procs
--   ui/     - the window and the native settings layer
--
-- Flow: build UI -> wire settings -> load per-account data once the tracking
-- ID is available -> start the chat reader feeding procs into the data layer.

local Stats    = require("data/stats")
local Colours  = require("data/colours")
local Reader   = require("chat/reader")
local UI       = require("ui/window")
local Settings = require("ui/settings")

-- Permissions. chatAccess is required for proc detection; trackingAccess lets
-- us separate saved data per account. Both are declared in plugin.json.
local hasChatAccess     = Plugin.HasPermission(PluginPermissions.chatAccess)
local hasTrackingAccess = Plugin.HasPermission(PluginPermissions.trackingAccess)
if not hasChatAccess then
    print("[ScavTracker] WARNING: chatAccess not granted - procs won't be detected")
end
if not hasTrackingAccess then
    print("[ScavTracker] WARNING: trackingAccess not granted - using shared data bucket")
end

-- Load global colour settings (not per-account).
Colours:Load()

-- Build the window (empty until data loads) and wire the settings layer.
UI.Init(Stats, Colours)
Settings.Init(Stats, function() UI.Refresh() end, UI, Colours)

-- Record a proc into the data layer and refresh the window.
local function recordProc(name, count)
    Stats:Add(name, count)
    UI.Refresh()
end

-- Load persisted data for the current account, then refresh the window.
local dataLoaded = false
local function loadForAccount(trackingID)
    Stats:SetPrefix(trackingID)
    Stats:Load()
    dataLoaded = true
    UI.Refresh()
end

-- Per-account data is namespaced by the player's tracking ID, which arrives a
-- few seconds after login (GetTrackingID returns nil until then). Defer the
-- load until it's available; without trackingAccess, use the shared bucket.
if not hasTrackingAccess then
    loadForAccount(nil)
else
    local pollTicks = 0
    local graceTicks = 500  -- ~10s at 50 ticks/sec before anon fallback
    Event.Logic.Subscribe("scavTrackerTrackingPoll", function()
        if dataLoaded then return end
        pollTicks = pollTicks + 1
        local trackingID
        pcall(function() trackingID = Player.GetTrackingID() end)
        if trackingID ~= nil then
            loadForAccount(trackingID)
            Event.Logic.Unsubscribe("scavTrackerTrackingPoll")
        elseif pollTicks >= graceTicks then
            loadForAccount(nil)
            Event.Logic.Unsubscribe("scavTrackerTrackingPoll")
        end
    end)
end

-- Start watching chat for component-gain procs.
Reader.Start(recordProc)

-- Clean up on unload/reload so event subscriptions don't leak across reloads.
function PluginShutdown()
    pcall(function() Reader.Stop() end)
    pcall(function() Event.Logic.Unsubscribe("scavTrackerTrackingPoll") end)
    pcall(function() Event.Logic.Unsubscribe("scavTrackerGrab") end)
    pcall(function() Event.SettingsLayerReady.Unsubscribe("scavTrackerSettings") end)
end
