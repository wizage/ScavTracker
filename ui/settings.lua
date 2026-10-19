-- ScavTracker / ui / settings
--
-- Populates the native settings layer (Settings icon in the Plugin Hub's
-- Manage tab) with a sort-order dropdown and a show/hide window toggle.
-- Requires "hasSettingsIcon": true in plugin.json and the SettingsLayerReady
-- event. The show/hide toggle lives here (always reachable) so the window can
-- be brought back after the X button hides it.

local Settings = {}

local S = require("ui/styles")

local Stats        -- data module, injected via Settings.Init
local UIRef        -- UI module, for the show/hide toggle
local onChangeCb   -- called after the sort mode changes (to refresh the window)

-- Sort options in display order: { value = Stats.SORT_*, label }.
local function sortOptions()
    return {
        { value = Stats.SORT_ORDER_RECEIVED,  label = "Order received" },
        { value = Stats.SORT_RARITY_COUNT,    label = "Rarity -> count" },
        { value = Stats.SORT_RARITY_RECEIVED, label = "Rarity -> order received" },
        { value = Stats.SORT_COUNT,           label = "Count" },
    }
end

local function try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("[ScavTracker] settings warn: " .. tostring(err))
    end
    return ok
end

-- Populate the settings layer component.
local function build(parent)
    local title = ui.Text.new(parent)
    title:SetSize(0, 24, 1.0, 0)
    title:SetPos(8, 8)
    title.content = "Scav Tracker - Sort order"
    title.font = S.FONT
    title:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)

    -- Sort-mode dropdown. List:Add(label, id); id is the Stats.SORT_* value.
    local opts = sortOptions()
    local list = ui.List.new(parent)
    list.stylesheetID = id.StyleSheet.DEFAULT
    list:SetSize(0, 28, 1.0, 0)
    list:SetPos(8, 40)
    try(function() list.dropdownMaxVisibleEntries = #opts end)  -- non-zero = dropdown
    try(function() list.maxSelected = 1 end)

    for _, opt in ipairs(opts) do
        list:Add(opt.label, opt.value)
    end
    try(function() list:SetEntrySelected(Stats:GetSortMode(), true, false) end)

    list:Subscribe(ui.Hook.ONSELECTIONCHANGED, function(component, entryID, eventType)
        if entryID == nil then return end
        if eventType ~= nil and ui.SelectionChangeEvent ~= nil
           and eventType == ui.SelectionChangeEvent.DESELECTED then
            return  -- ignore deselect events
        end
        Stats:SetSortMode(entryID)
        if onChangeCb then onChangeCb() end
    end)

    -- Show/hide window toggle.
    if UIRef ~= nil then
        local toggle = ui.Button.new(parent)
        toggle.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        toggle:SetSize(0, 28, 1.0, 0)
        toggle:SetPos(8, 80)
        try(function() toggle.canToggle = true end)
        local function syncLabel()
            local shown = UIRef.IsVisible()
            toggle.label = shown and "Hide window" or "Show window"
            try(function() toggle.isToggled = shown end)
        end
        syncLabel()
        toggle:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
            UIRef.Toggle()
            syncLabel()
        end)
    end
end

-- Wire up the SettingsLayerReady event. `refreshCb` re-renders the window on
-- sort change; `uiModule` provides the show/hide toggle.
function Settings.Init(statsModule, refreshCb, uiModule)
    Stats = statsModule
    onChangeCb = refreshCb
    UIRef = uiModule

    Event.SettingsLayerReady.Subscribe("scavTrackerSettings", function(e)
        local root = e.component
        if root == nil then return end
        try(build, root)  -- layer is cleared before this event; just populate
    end)
end

return Settings
