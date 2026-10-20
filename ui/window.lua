-- ScavTracker / ui / window
--
-- The plugin's table UI: three tabs (Session / Trip / All Time) over a
-- scrollable table of component counts. The same table is rendered into one or
-- more "surfaces": the draggable/resizable floating window and the ribbon
-- content panel. Each surface has its own active tab + scroll, so the two can
-- show different tabs independently; they share only the underlying data.
-- Rows are hand-drawn Rectangles + Text (the interactive ui.List renders as a
-- dropdown, so it can't be used for the table).
--
-- Style constants (sizes, colours, font) live in ui/styles, referenced as S.*.
-- Public API:
--   UI.Init(stats, colours)        - build the floating window
--   UI.MountContent(component)      - render the table into the ribbon layer
--   UI.SetSettingsModule(mod)       - inject ui/settings (for the gear button)
--   UI.Refresh()                    - redraw all surfaces
--   UI.Show/Hide/Toggle/IsVisible() - floating window visibility
--   UI.ShowSettings/HideSettings()  - the self-contained settings window
-- Tab keys match Stats:GetCounter: "session" | "trip" | "allTime".

local UI = {}

local S = require("ui/styles")

local TABS = {
    { key = "session", label = "Session",  resettable = true  },
    { key = "trip",    label = "Trip",     resettable = true  },
    { key = "allTime", label = "All Time", resettable = false },
}

local Stats
local Colours         -- data/colours module (rarity text colouring)
local SettingsMod     -- ui/settings module, injected to build the settings window
local window
local settingsWin     -- self-contained settings window (built lazily)
local root            -- root vertical Panel (resized with the window)
local resizeHandle    -- bottom-right resize grip
local buttonBar       -- footer panel holding the reset button
local resetButton
local uiVisible = true   -- window shown/hidden (persisted)

-- Surfaces: each is an independent place the same table is drawn. The floating
-- window body is one surface; the ribbon content layer is another. Each surface
-- keeps its OWN active tab, scroll offset, tab buttons, and reset bar, so the
-- pop-out window and the ribbon panel can show different tabs independently.
-- They share only the underlying data. A surface =
--   { body = Layer, scrollY = number, activeTab = key,
--     tabButtons = { key -> Button }, buttonBar = Panel|nil }.
local surfaces = {}
local contentSurf     -- the ribbon content surface (so we can drop it on remount)
local contentSpriteBtns = {}   -- ribbon sprite buttons, to clear press-state on remount
-- Press-state registry for sprite buttons (keyed by button). Declared here so
-- dropContentSurface can clear ribbon entries on remount. Populated by
-- spriteButton; swept each logic tick (see sweepPressStates).
local pressReg = {}
-- Register a table surface (its own body Layer). Each surface tracks its own
-- active tab, scroll, tab buttons, and reset bar. Returns the surface table.
local function addSurface(bodyLayer)
    local surf = {
        body = bodyLayer,
        scrollY = 0,
        activeTab = "session",
        tabButtons = {},
        buttonBar = nil,
    }
    surfaces[#surfaces + 1] = surf
    return surf
end

-- Live window geometry (interface units), shared by drag + resize + persist.
local winX, winY = 40, 40
local winW, winH = S.WIN_W, S.WIN_H

-- Guarded call: runs fn(...) in pcall, logs a warning on failure.
local function try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        print("[ScavTracker] UI warn: " .. tostring(err))
    end
    return ok
end

-- Remove all existing row components from a surface's table body.
local function clearRows(surf)
    local b = surf and surf.body
    if b == nil then return end
    if type(b.DeleteAll) == "function" then
        try(function() b:DeleteAll() end)
    end
end

-- Forward declarations so earlier functions can reference these locals.
local bodyHeight, bodyWidth, refreshList, applyGeometry, saveGeometry, renderSurface

-- Build row i (1-based) into surf.body with body-relative y.
-- Returns true if the row fit the visible band and was drawn.
local function buildRow(surf, i, name, count, rarity)
    local body = surf.body
    local y = (i - 1) * S.ROW_H - surf.scrollY
    local bh = bodyHeight(surf)

    -- Cull rows that don't fully fit the table Layer.
    if y < 0 or (y + S.ROW_H) > bh then
        return false
    end

    local bg = ui.Rectangle.new(body)
    bg:SetSize(0, S.ROW_H, 1.0, 0)
    bg:SetPos(0, y)
    bg.fill = true
    bg.colour = (i % 2 == 0) and S.COL_ROW_B or S.COL_ROW_A

    -- Name cell: left, leaves room on the right for count + scrollbar.
    local nameText = ui.Text.new(body)
    nameText:SetSize(-88, S.ROW_H, 1.0, 0)
    nameText:SetPos(8, y)
    nameText.content = name
    nameText.font = S.FONT
    -- Colour the name by rarity if the colour setting is enabled, else white.
    local rarityCol = Colours and Colours:ForRarity(rarity)
    nameText.colour = rarityCol or S.COL_NAME
    nameText:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)

    -- Count cell: full-width box inset on both sides; right-aligned text puts
    -- the number at the right edge (clear of the scrollbar).
    local countText = ui.Text.new(body)
    countText:SetSize(-(8 + S.ROW_RIGHT_PAD), S.ROW_H, 1.0, 0)
    countText:SetPos(8, y)
    countText.content = tostring(count)
    countText.font = S.FONT
    countText.colour = S.COL_COUNT
    countText:AlignTo(ui.AlignMode.BOTTOMRIGHT, ui.AlignMode.CENTRE)

    return true
end

-- Apply window geometry (pos + size), reflow the root panel + resize handle,
-- then rebuild the table so rows re-cull to the new size.
function applyGeometry()
    if window == nil then return end
    try(function() window:SetSize(winW, winH) end)
    try(function() window:SetPos(winX, winY) end)
    if root ~= nil then
        try(function() root:SetSize(-24, -(S.TITLE_H + 16), 1.0, 1.0) end)
        try(function() root:SetPos(12, S.TITLE_H) end)
    end
    if resizeHandle ~= nil then
        try(function() resizeHandle:SetX(-S.HANDLE_SZ, 1.0) end)
        try(function() resizeHandle:SetY(-S.HANDLE_SZ, 1.0) end)
    end
    if refreshList then refreshList() end
end

-- Persist window geometry so it survives reloads.
function saveGeometry()
    pcall(function()
        PersistentDB:SetStructuredData("scav_winGeom",
            { x = winX, y = winY, w = winW, h = winH })
    end)
end

-- ---- Drag/resize grab engine -------------------------------------------
-- ONHOLD only fires while the cursor is over the handle, which stalls fast
-- drags. So ONHOLD is just a "button is held" heartbeat (UI._beginGrab), and a
-- global Event.Logic tick does the actual movement from the live Mouse
-- position - keeping the window pinned to the cursor even when it outruns the
-- handle. The grab ends when the heartbeat goes stale (button released).
local grabKind       = nil     -- "move" | "resize" | "scroll" | nil
local grabEdges      = ""      -- for resize: which edges (l/r/t/b) are dragged
local grabBaseX, grabBaseY     = 0, 0   -- window position at grab start
local grabBaseW, grabBaseH     = 0, 0   -- window size at grab start
local grabStartMX, grabStartMY = 0, 0   -- mouse pos at grab start
local grabBaseScroll = 0       -- scrollY at scroll-grab start
local grabScrollScale = 1      -- maps thumb pixel travel -> scrollY units
local grabScrollMax  = 0       -- max scrollY at scroll-grab start
local grabScrollSurf = nil     -- the surface being scroll-grabbed
local grabLastTick   = 0
local grabCurTick    = 0
local sweepPressStates   -- forward decl; defined with the sprite-button helpers

-- Begin (or refresh) a grab. kind = "move" | "resize" | "scroll".
-- resize: `edges` names which edges follow the cursor (l/r/t/b).
-- scroll: `scale` maps one pixel of thumb travel to scrollY units, `smax` is
--         the max scrollY (clamp), and `surf` is the surface being scrolled.
function UI._beginGrab(kind, edges, scale, smax, surf)
    grabLastTick = grabCurTick
    if grabKind == kind and grabEdges == (edges or "") then return end
    grabKind = kind
    grabEdges = edges or ""
    grabBaseX, grabBaseY = winX, winY
    grabBaseW, grabBaseH = winW, winH
    grabScrollSurf = surf
    grabBaseScroll = surf and surf.scrollY or 0
    grabScrollScale = scale or 1
    grabScrollMax = smax or 0
    grabStartMX, grabStartMY = Mouse.GetX(), Mouse.GetY()
end

local function grabTick(e)
    grabCurTick = (e and e.logicTick) or (grabCurTick + 1)
    if sweepPressStates then sweepPressStates() end
    if grabKind == nil then return end

    -- Heartbeat stale => button released, end the grab.
    if grabCurTick - grabLastTick > 1 then
        grabKind = nil
        saveGeometry()
        return
    end

    if not Mouse.IsAvailable() then return end
    local dx = Mouse.GetX() - grabStartMX
    local dy = Mouse.GetY() - grabStartMY

    if grabKind == "move" then
        winX = grabBaseX + dx
        winY = grabBaseY + dy
        try(function() window:SetPos(winX, winY) end)
        return
    end

    if grabKind == "scroll" then
        -- Thumb drag: mouse Y delta * scale = scrollY delta, clamped.
        if grabScrollSurf == nil then return end
        local ns = grabBaseScroll + dy * grabScrollScale
        if ns < 0 then ns = 0 elseif ns > grabScrollMax then ns = grabScrollMax end
        grabScrollSurf.scrollY = ns
        renderSurface(grabScrollSurf)
        return
    end

    -- Resize: start from the base geometry, then adjust per dragged edge.
    local nx, ny = grabBaseX, grabBaseY
    local nw, nh = grabBaseW, grabBaseH

    if string.find(grabEdges, "r", 1, true) then
        nw = grabBaseW + dx
    elseif string.find(grabEdges, "l", 1, true) then
        nw = grabBaseW - dx
        nx = grabBaseX + dx
    end
    if string.find(grabEdges, "b", 1, true) then
        nh = grabBaseH + dy
    elseif string.find(grabEdges, "t", 1, true) then
        nh = grabBaseH - dy
        ny = grabBaseY + dy
    end

    -- Clamp to min/max; when dragging a left/top edge, adjusting the clamp
    -- must also correct the origin so the opposite edge stays put.
    if nw < S.MIN_W then
        if string.find(grabEdges, "l", 1, true) then nx = nx - (S.MIN_W - nw) end
        nw = S.MIN_W
    elseif nw > S.MAX_W then
        if string.find(grabEdges, "l", 1, true) then nx = nx + (nw - S.MAX_W) end
        nw = S.MAX_W
    end
    if nh < S.MIN_H then
        if string.find(grabEdges, "t", 1, true) then ny = ny - (S.MIN_H - nh) end
        nh = S.MIN_H
    elseif nh > S.MAX_H then
        if string.find(grabEdges, "t", 1, true) then ny = ny + (nh - S.MAX_H) end
        nh = S.MAX_H
    end

    winX, winY, winW, winH = nx, ny, nw, nh
    applyGeometry()
end

-- Body band height for rows. The root Panel sizes the table Layer, so read its
-- resolved height; fall back to an estimate before layout settles.
function bodyHeight(surf)
    local b = surf and surf.body
    local h
    if b ~= nil then pcall(function() h = b.height end) end
    if type(h) == "number" and h > 0 then return h end
    return winH - S.TITLE_H - S.TAB_H - S.BUTTON_H - 24
end

-- Inner width of the table Layer (for scrollbar placement).
function bodyWidth(surf)
    local b = surf and surf.body
    local w
    if b ~= nil then pcall(function() w = b.width end) end
    if type(w) == "number" and w > 0 then return w end
    return winW - 16
end

local function visibleRowCount(surf)
    return math.floor(bodyHeight(surf) / S.ROW_H)
end

local function maxScroll(surf, numRows)
    local overflow = numRows - visibleRowCount(surf)
    if overflow <= 0 then return 0 end
    return overflow * S.ROW_H
end

-- Transparent wheel-capture surface filling the table Layer. Recreated each
-- refresh because clearRows()/DeleteAll removes it with the rows.
local function buildScrollCatcher(surf)
    local body = surf.body
    local catcher = ui.Rectangle.new(body)
    catcher:SetSize(0, 0, 1.0, 1.0)
    catcher:SetPos(0, 0)
    catcher.fill = true
    catcher.colour = S.COL_TRANSPARENT
    try(function() catcher.clickthrough = false end)
    try(function() catcher.enabled = true end)
    catcher:Subscribe(ui.Hook.ONSCROLLWHEEL, function(self, delta)
        local rows = Stats:GetSorted(surf.activeTab)
        local maxY = maxScroll(surf, #rows)
        if maxY <= 0 then return end
        surf.scrollY = surf.scrollY - (delta * S.ROW_H)
        if surf.scrollY < 0 then surf.scrollY = 0 end
        if surf.scrollY > maxY then surf.scrollY = maxY end
        renderSurface(surf)
    end)
end

-- Draw the scrollbar track + thumb on the right edge of the table (only on
-- overflow). Parented to surf.body; coordinates are Layer-relative.
local function buildScrollbar(surf, numRows)
    local body = surf.body
    local maxY = maxScroll(surf, numRows)
    if maxY <= 0 then return end

    local bh = bodyHeight(surf)
    local trackX = bodyWidth(surf) - S.SB_W

    local track = ui.Rectangle.new(body)
    track:SetSize(S.SB_W, bh, 0, 0)
    track:SetPos(trackX, 0)
    track.fill = true
    track.colour = S.COL_SB_TRACK

    local totalContent = numRows * S.ROW_H
    local thumbH = math.max(16, math.floor(bh * (bh / totalContent)))
    local travel = bh - thumbH
    local frac = (maxY > 0) and (surf.scrollY / maxY) or 0
    local thumbY = math.floor(travel * frac)

    local thumb = ui.Rectangle.new(body)
    thumb:SetSize(S.SB_W, thumbH, 0, 0)
    thumb:SetPos(trackX, thumbY)
    thumb.fill = true
    thumb.colour = S.COL_SB_THUMB

    -- Grabbable thumb: dragging it scrolls. scale maps 1px of thumb travel to
    -- scrollY units (maxScroll / track travel); smax clamps to maxScroll.
    local scale = (travel > 0) and (maxY / travel) or 0
    try(function() thumb.clickthrough = false end)
    try(function() thumb.enabled = true end)
    thumb:Subscribe(ui.Hook.ONHOLD, function()
        if not Mouse.IsAvailable() then return end
        UI._beginGrab("scroll", nil, scale, maxY, surf)
    end)
end

-- Render one surface's table for its own active tab.
function renderSurface(surf)
    if surf == nil or surf.body == nil then return end
    if Stats == nil then return end

    -- Reset bar is only shown on resettable tabs for THIS surface. Hiding it
    -- AND collapsing its height to 0 makes the vertical Panel reclaim the slot
    -- so the table grows all the way down. Done before building rows so
    -- bodyHeight() reflects the new size.
    local resettable = false
    for _, tab in ipairs(TABS) do
        if tab.key == surf.activeTab then resettable = tab.resettable end
    end
    if surf.buttonBar ~= nil then
        try(function() surf.buttonBar.hidden = not resettable end)
        try(function()
            surf.buttonBar:SetSize(0, resettable and S.BUTTON_H or 0, 1.0, 0)
        end)
    end

    -- Clamp this surface's scroll to its own content/size.
    local rows = Stats:GetSorted(surf.activeTab) or {}
    local maxY = maxScroll(surf, #rows)
    if surf.scrollY > maxY then surf.scrollY = maxY end
    if surf.scrollY < 0 then surf.scrollY = 0 end

    clearRows(surf)
    buildScrollCatcher(surf)
    for i, row in ipairs(rows) do
        try(buildRow, surf, i, row.name, row.count, row.rarity)
    end
    try(buildScrollbar, surf, #rows)
end

-- Rebuild every mounted surface (each renders its own active tab).
function refreshList()
    for _, surf in ipairs(surfaces) do
        renderSurface(surf)
    end
end

-- Switch one surface to a tab (independent of other surfaces).
local function selectTab(surf, key)
    surf.activeTab = key
    surf.scrollY = 0
    for k, btn in pairs(surf.tabButtons) do
        try(function() btn.isToggled = (k == key) end)  -- highlight active tab
    end
    renderSurface(surf)
end

function UI.Refresh()
    refreshList()
end

-- ---- Ribbon content layer -------------------------------------------------
-- The content layer (ribbon panel in the Plugins window) hosts a second copy
-- of the same table, always docked and live. It is rebuilt each time
-- ContentLayerReady fires (the client clears the layer first), so this drops
-- any previous content surface and registers the fresh one.

-- Remove the previous content surface from the surfaces list (its components
-- are already gone because the client cleared the layer).
local function dropContentSurface()
    if contentSurf == nil then return end
    for i, s in ipairs(surfaces) do
        if s == contentSurf then table.remove(surfaces, i) break end
    end
    contentSurf = nil
    -- Drop the old ribbon sprite buttons' press-state entries (their components
    -- are gone; leaving them would slowly accumulate dead entries).
    for _, btn in ipairs(contentSpriteBtns) do
        pressReg[btn] = nil
    end
    contentSpriteBtns = {}
end

-- Resolve a sprite's state variants. The game names some buttons with
-- _NML/_OVR/_PRESSED suffixes and others as a single flat id, so try the
-- suffixed names first and fall back to the base id. Returns nml, ovr, pressed
-- (ovr/pressed default to nml when absent).
local function spriteStates(base)
    local S_ = id.Sprite
    -- id.Sprite returns -1 (not nil) for names that don't exist, so treat any
    -- negative/zero id as absent. Many icons are flat ids with no _NML/_OVR
    -- variants, so this falls back to the base id.
    local function get(key)
        local v
        pcall(function() v = S_[key] end)
        if type(v) ~= "number" or v < 0 then return nil end
        return v
    end
    local nml     = get(base .. "_NML") or get(base)
    local ovr     = get(base .. "_OVR") or nml
    local pressed = get(base .. "_PRESSED") or ovr
    return nml, ovr, pressed
end

-- Press-state registry for sprite buttons. ONHOLD is a per-tick heartbeat (it
-- keeps firing while held and may fire once more around release), so resetting
-- the sprite in ONCLICK races and leaves it stuck on "pressed". Instead, each
-- ONHOLD records the current logic tick; a logic-tick sweep restores any button
-- whose heartbeat has gone stale (released) to hover (if the mouse is still
-- over it) or normal. (pressReg is declared near the top so dropContentSurface
-- can clear ribbon entries on remount.)

-- Restore any sprite buttons whose press heartbeat went stale. Called from the
-- global logic tick (grabCurTick is advanced there before this runs).
function sweepPressStates()
    for btn, st in pairs(pressReg) do
        if st.held and (grabCurTick - st.tick) > 1 then
            st.held = false
            try(function() btn.spriteID = st.over and st.ovr or st.nml end)
        end
    end
end

-- Resolve a single sprite id by name, treating -1/invalid as nil.
local function spriteId(name)
    if name == nil then return nil end
    local v
    pcall(function() v = id.Sprite[name] end)
    if type(v) ~= "number" or v < 0 then return nil end
    return v
end

-- Create a native sprite button on `parent` wired to hover/press/leave states
-- (mirrors the floating window's close button) that calls onClick when pressed.
-- `spec` is either a base-name string (tries _NML/_OVR/_PRESSED then the flat
-- id) or an explicit table { nml = "..", ovr = "..", pressed = ".." } for
-- sprites whose variants don't follow the _NML/_OVR/_PRESSED naming.
local function spriteButton(parent, spec, onClick)
    local nml, ovr, pressed
    if type(spec) == "table" then
        nml     = spriteId(spec.nml)
        ovr     = spriteId(spec.ovr) or nml
        pressed = spriteId(spec.pressed) or ovr
    else
        nml, ovr, pressed = spriteStates(spec)
    end
    if nml == nil then return nil end
    local btn = ui.Sprite.new(parent)
    btn.spriteID = nml
    try(function() btn.clickthrough = false end)
    try(function() btn.enabled = true end)

    -- Register press-state so the logic-tick sweep can restore it on release.
    local st = { nml = nml, ovr = ovr, pressed = pressed, over = false, held = false, tick = 0 }
    pressReg[btn] = st

    btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
        st.over = true
        if not st.held then btn.spriteID = ovr end
    end)
    btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        st.over = false
        if not st.held then btn.spriteID = nml end
    end)
    btn:Subscribe(ui.Hook.ONHOLD, function()
        -- Heartbeat while the button is held: show pressed and stamp the tick.
        st.held = true
        st.tick = grabCurTick
        btn.spriteID = pressed
    end)
    btn:Subscribe(ui.Hook.ONCLICK, function()
        if onClick then onClick() end
    end)
    return btn
end

-- Build the full table UI into a ribbon content component (a ui.Layer). Mirrors
-- the floating window's layout (tab bar / table / reset) minus the frame +
-- drag/resize chrome, plus a pop-out icon where the window's X sits.
function UI.MountContent(component)
    if component == nil then return end
    dropContentSurface()

    -- Header strip: title on the left, icon buttons on the right.
    local HEADER_H = 22
    local title = ui.Text.new(component)
    title:SetSize(-72, HEADER_H, 1.0, 0)
    title:SetPos(6, 2)
    title.content = "Scav Tracker"
    title.font = S.FONT
    title:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)

    -- Pop-out button (top-right, where the floating window's red X is): native
    -- minimise sprite with explicit state variants (5 normal, 3 hover, 4
    -- pressed). Shows the floating window.
    local pop = spriteButton(component, {
        nml     = "RS3_BTN_MINIMISE_5",
        ovr     = "RS3_BTN_MINIMISE_3",
        pressed = "RS3_BTN_MINIMISE_4",
    }, function() UI.Show() end)
    if pop ~= nil then
        pop:SetSize(18, 18, 0, 0)
        pop:SetX(-24, 1.0)
        pop:SetY(2)
        contentSpriteBtns[#contentSpriteBtns + 1] = pop
    else
        -- Fallback: labelled button if the sprite id isn't present.
        local popBtn = ui.Button.new(component)
        popBtn:SetSize(40, HEADER_H - 2, 0, 0)
        popBtn:SetX(-42, 1.0)
        popBtn:SetY(1)
        popBtn.label = "Pop"
        popBtn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        popBtn:Subscribe(ui.Hook.ONBUTTONPRESSED, function() UI.Show() end)
    end

    -- Settings button (left of the pop-out): native plugin-hub settings icon.
    -- Opens the self-contained settings window.
    local gear = spriteButton(component, "RS3_ICON_PLUGIN_HUB_SETTINGS_ACTIVE",
        function() UI.ShowSettings() end)
    if gear ~= nil then
        gear:SetSize(18, 18, 0, 0)
        gear:SetX(-46, 1.0)
        gear:SetY(2)
        contentSpriteBtns[#contentSpriteBtns + 1] = gear
    else
        local gearBtn = ui.Button.new(component)
        gearBtn:SetSize(48, HEADER_H - 2, 0, 0)
        gearBtn:SetX(-92, 1.0)
        gearBtn:SetY(1)
        gearBtn.label = "Cfg"
        gearBtn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        gearBtn:Subscribe(ui.Hook.ONBUTTONPRESSED, function() UI.ShowSettings() end)
    end

    -- Vertical layout under the header: [tab bar] / [table] / [reset].
    local panel = ui.Panel.new(component)
    panel.isVertical = true
    panel.spacing = 4
    panel:SetSize(-8, -(HEADER_H + 8), 1.0, 1.0)
    panel:SetPos(4, HEADER_H + 2)

    -- Create this surface up front so its tab buttons / reset bar bind to it.
    -- Its body Layer is assigned after the tab bar (vertical layout order).
    local surf = addSurface(nil)
    contentSurf = surf

    -- Tab bar (controls only this surface's active tab).
    local tabBar = ui.Panel.new(panel)
    tabBar.isVertical = false
    tabBar.spacing = 4
    tabBar:SetSize(0, S.TAB_H, 1.0, 0)
    for _, tab in ipairs(TABS) do
        local btn = ui.Button.new(tabBar)
        btn:SetSize(0, 0, 1.0, 1.0)
        btn.label = tab.label
        btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        try(function() btn.canToggle = true end)
        try(function() btn.isToggled = (tab.key == surf.activeTab) end)
        btn:Subscribe(ui.Hook.ONBUTTONPRESSED, function() selectTab(surf, tab.key) end)
        surf.tabButtons[tab.key] = btn
    end

    -- Table body for this surface.
    local cbody = ui.Layer.new(panel)
    cbody:SetSize(0, 0, 1.0, 1.0)
    surf.body = cbody

    -- Reset bar: hidden on non-resettable tabs by renderSurface. Hiding the
    -- whole bar (not just the button) lets the Panel give space back to the
    -- table. Acts on this surface's active tab.
    local cBar = ui.Panel.new(panel)
    cBar.isVertical = false
    cBar:SetSize(0, S.BUTTON_H, 1.0, 0)
    surf.buttonBar = cBar
    local cReset = ui.Button.new(cBar)
    cReset:SetSize(0, 0, 1.0, 1.0)
    cReset.label = "Reset"
    cReset.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    cReset:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if surf.activeTab == "session" then
            Stats:ResetSession()
        elseif surf.activeTab == "trip" then
            Stats:ResetManualSession()
        end
        refreshList()
    end)

    renderSurface(surf)
end

-- ---- Show / hide (tracking continues regardless; visibility persisted) ----
local function applyVisibility()
    if window ~= nil then
        try(function() window.hidden = not uiVisible end)
    end
end

function UI.IsVisible() return uiVisible end

function UI.Show()
    uiVisible = true
    applyVisibility()
    pcall(function() PersistentDB:SetBool("scav_uiVisible", true) end)
end

function UI.Hide()
    uiVisible = false
    applyVisibility()
    pcall(function() PersistentDB:SetBool("scav_uiVisible", false) end)
end

function UI.Toggle()
    if uiVisible then UI.Hide() else UI.Show() end
end

-- Inject the settings module (avoids a require cycle: settings.lua requires UI).
function UI.SetSettingsModule(mod)
    SettingsMod = mod
end

-- ---- Self-contained settings window ---------------------------------------
-- The native settings layer can't be opened programmatically, so the ribbon
-- panel's settings icon shows this raw window instead. Built lazily the first
-- time, then just shown/hidden. Reuses ui/settings' BuildInto for the controls.
local SETTINGS_W, SETTINGS_H = 300, 300

local function buildSettingsWindow()
    local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if gameWindow == nil then return end

    settingsWin = ui.Layer.new(gameWindow)
    try(function() settingsWin.clickthrough = false end)
    try(function() settingsWin.enabled = true end)
    settingsWin:SetSize(SETTINGS_W, SETTINGS_H)
    -- Centre on screen: anchor to the parent's midpoint (0.5) and offset back by
    -- half the window size so the window's centre lands on the screen centre.
    settingsWin:SetX(-SETTINGS_W / 2, 0.5)
    settingsWin:SetY(-SETTINGS_H / 2, 0.5)

    -- HUD frame (same 6-piece set as the main window, simplified).
    local EDGE_T, CORNER = 2, 8
    local bg = ui.Sprite.new(settingsWin)
    bg.spriteID = id.Sprite.RS3_HUD_WINDOW_CONTENT_TILE
    bg:SetPos(EDGE_T, EDGE_T)
    bg:SetSize(-EDGE_T * 2, -EDGE_T * 2, 1.0, 1.0)
    try(function() bg.isTiling = true end)
    try(function() bg.clickthrough = false end)
    try(function() bg.enabled = true end)

    local function frameSprite(spriteID, setup, flipH, flipV)
        local s = ui.Sprite.new(settingsWin)
        s.spriteID = spriteID
        setup(s)
        try(function() s.clickthrough = true end)
        if flipH then try(function() s.isFlippedHorizontally = true end) end
        if flipV then try(function() s.isFlippedVertical = true end) end
    end
    local TOP  = id.Sprite.RS3_HUD_WINDOW_TOP_TILE
    local BOT  = id.Sprite.RS3_HUD_WINDOW_BOTTOM_TILE
    local SIDE = id.Sprite.RS3_HUD_WINDOW_SIDE_TILE
    local CT   = id.Sprite.RS3_HUD_WINDOW_CORNER_TOP
    local CB   = id.Sprite.RS3_HUD_WINDOW_CORNER_BOTTOM
    frameSprite(TOP, function(s) s:SetPos(CORNER, 0); s:SetSize(-CORNER * 2, EDGE_T, 1.0, 0); try(function() s.isTiling = true end) end)
    frameSprite(BOT, function(s) s:SetPos(CORNER, -EDGE_T, 0, 1.0); s:SetSize(-CORNER * 2, EDGE_T, 1.0, 0); try(function() s.isTiling = true end) end)
    frameSprite(SIDE, function(s) s:SetPos(0, CORNER); s:SetSize(EDGE_T, -CORNER * 2, 0, 1.0); try(function() s.isTiling = true end) end)
    frameSprite(SIDE, function(s) s:SetPos(-EDGE_T, CORNER, 1.0); s:SetSize(EDGE_T, -CORNER * 2, 0, 1.0); try(function() s.isTiling = true end) end, true)
    frameSprite(CT, function(s) s:SetPos(0, 0); s:SetSize(CORNER, CORNER, 0, 0) end)
    frameSprite(CT, function(s) s:SetPos(-CORNER, 0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end, true)
    frameSprite(CB, function(s) s:SetPos(0, -CORNER, 0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end)
    frameSprite(CB, function(s) s:SetPos(-CORNER, -CORNER, 1.0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end, true)

    -- Title.
    local titleText = ui.Text.new(settingsWin)
    titleText:SetSize(0, S.TITLE_H, 1.0, 0)
    titleText:SetPos(0, 0)
    titleText.content = "Scav Tracker - Settings"
    titleText.font = S.FONT
    titleText:AlignTo(ui.AlignMode.CENTRE)

    -- Close button (native red X), top-right.
    local closeBtn = ui.Sprite.new(settingsWin)
    closeBtn:SetSize(20, 20, 0, 0)
    closeBtn:SetX(-28, 1.0)
    closeBtn:SetY(9)
    closeBtn.spriteID = id.Sprite.RS3_BTN_MODAL_WINDOW_1_CLOSE_NML
    try(function() closeBtn.clickthrough = false end)
    try(function() closeBtn.enabled = true end)
    closeBtn:Subscribe(ui.Hook.ONMOUSEOVER, function() closeBtn.spriteID = id.Sprite.RS3_BTN_MODAL_WINDOW_1_CLOSE_OVR end)
    closeBtn:Subscribe(ui.Hook.ONMOUSELEAVE, function() closeBtn.spriteID = id.Sprite.RS3_BTN_MODAL_WINDOW_1_CLOSE_NML end)
    closeBtn:Subscribe(ui.Hook.ONCLICK, function() UI.HideSettings() end)

    -- Content region below the title: reuse the settings controls.
    local content = ui.Layer.new(settingsWin)
    content:SetSize(-24, -(S.TITLE_H + 16), 1.0, 1.0)
    content:SetPos(12, S.TITLE_H)
    if SettingsMod and SettingsMod.BuildInto then
        try(function() SettingsMod.BuildInto(content) end)
    end
end

function UI.ShowSettings()
    if settingsWin == nil then buildSettingsWindow() end
    if settingsWin ~= nil then try(function() settingsWin.hidden = false end) end
end

function UI.HideSettings()
    if settingsWin ~= nil then try(function() settingsWin.hidden = true end) end
end

function UI.Init(statsModule, coloursModule)
    Stats = statsModule
    Colours = coloursModule

    local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if gameWindow == nil then
        print("[ScavTracker] UI: could not find plugin build layer; UI not created")
        return
    end

    -- Root window: a plain Layer (no built-in frame) so our HUD sprite frame
    -- is the only frame and coincides exactly with the window rect. A
    -- background tile sprite fills the interior (PrettyUI's structure). Using a
    -- GroupBox here caused a mismatched inner frame + click-through dead zones.
    window = ui.Layer.new(gameWindow)
    try(function() window.clickthrough = false end)  -- block pass-through to game
    try(function() window.enabled = true end)

    -- Load persisted geometry (falls back to defaults) and apply it.
    -- Uses a fixed key (not the per-account prefix): window position/size is a
    -- UI preference, and the prefix isn't set yet at Init time anyway, so a
    -- prefixed key would never match on load -> the window would jump.
    local gx = PersistentDB and PersistentDB:GetStructuredData("scav_winGeom")
    if type(gx) == "table" then
        winX = tonumber(gx.x) or winX
        winY = tonumber(gx.y) or winY
        winW = tonumber(gx.w) or winW
        winH = tonumber(gx.h) or winH
    end
    window:SetSize(winW, winH)
    window:SetPos(winX, winY)

    -- Subtle HUD-window frame (matches the game's native info panels - lighter
    -- than the ornate modal frame). A 6-piece set: content fill, top/bottom
    -- tiles, side tiles, and top/bottom corners. Built first so content renders
    -- on top. CORNER is the frame corner size.
    local CORNER = 8
    local function frameSprite(spriteID, setup, flipH, flipV)
        local s = ui.Sprite.new(window)
        s.spriteID = spriteID
        setup(s)
        try(function() s.clickthrough = true end)
        if flipH then try(function() s.isFlippedHorizontally = true end) end
        if flipV then try(function() s.isFlippedVertical = true end) end
        return s
    end

    -- Content fill (interior background), inset by the thin edge (2px) so it
    -- fills right up to the frame edges with no bare gap.
    local EDGE_T = 2
    local bg = ui.Sprite.new(window)
    bg.spriteID = id.Sprite.RS3_HUD_WINDOW_CONTENT_TILE
    bg:SetPos(EDGE_T, EDGE_T)
    bg:SetSize(-EDGE_T * 2, -EDGE_T * 2, 1.0, 1.0)
    try(function() bg.isTiling = true end)
    try(function() bg.clickthrough = false end)  -- solid surface: capture input
    try(function() bg.enabled = true end)

    local TOP  = id.Sprite.RS3_HUD_WINDOW_TOP_TILE
    local BOT  = id.Sprite.RS3_HUD_WINDOW_BOTTOM_TILE
    local SIDE = id.Sprite.RS3_HUD_WINDOW_SIDE_TILE
    local CT   = id.Sprite.RS3_HUD_WINDOW_CORNER_TOP
    local CB   = id.Sprite.RS3_HUD_WINDOW_CORNER_BOTTOM

    -- Top + bottom edge tiles. The HUD edge sprite is a thin line (~2px); force
    -- it to CORNER height stretches/repeats it and causes an artifact, so draw
    -- it at its thin natural height (EDGE_T) flush against the top/bottom.
    frameSprite(TOP, function(s) s:SetPos(CORNER, 0); s:SetSize(-CORNER * 2, EDGE_T, 1.0, 0); try(function() s.isTiling = true end) end)
    frameSprite(BOT, function(s) s:SetPos(CORNER, -EDGE_T, 0, 1.0); s:SetSize(-CORNER * 2, EDGE_T, 1.0, 0); try(function() s.isTiling = true end) end)
    -- Left + right side tiles (also thin).
    frameSprite(SIDE, function(s) s:SetPos(0, CORNER); s:SetSize(EDGE_T, -CORNER * 2, 0, 1.0); try(function() s.isTiling = true end) end)
    frameSprite(SIDE, function(s) s:SetPos(-EDGE_T, CORNER, 1.0); s:SetSize(EDGE_T, -CORNER * 2, 0, 1.0); try(function() s.isTiling = true end) end, true)
    -- Corners: cornerTop/cornerBottom are pre-oriented for their edge, so only
    -- the right-hand ones need a horizontal flip (no vertical flip needed).
    frameSprite(CT, function(s) s:SetPos(0, 0); s:SetSize(CORNER, CORNER, 0, 0) end)
    frameSprite(CT, function(s) s:SetPos(-CORNER, 0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end, true)
    frameSprite(CB, function(s) s:SetPos(0, -CORNER, 0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end)
    frameSprite(CB, function(s) s:SetPos(-CORNER, -CORNER, 1.0, 1.0); s:SetSize(CORNER, CORNER, 0, 0) end, true)


    -- Global per-tick driver for drag/resize (keeps window pinned to cursor).
    Event.Logic.Subscribe("scavTrackerGrab", grabTick)

    -- Title label centred within the titlebar strip.
    local titleText = ui.Text.new(window)
    titleText:SetSize(0, S.TITLE_H, 1.0, 0)
    titleText:SetPos(0, 0)
    titleText.content = "Scav Tracker"
    titleText.font = S.FONT
    titleText:AlignTo(ui.AlignMode.CENTRE)

    -- Transparent drag strip over the title strip (captures drag input).
    local dragStrip = ui.Rectangle.new(window)
    dragStrip:SetSize(0, S.TITLE_H, 1.0, 0)
    dragStrip:SetPos(0, 0)
    dragStrip.fill = true
    dragStrip.colour = S.COL_TRANSPARENT
    try(function() dragStrip.clickthrough = false end)
    try(function() dragStrip.enabled = true end)
    dragStrip:Subscribe(ui.Hook.ONHOLD, function()
        if not Mouse.IsAvailable() then return end
        UI._beginGrab("move")
    end)

    -- Close (X) button, top-right: the native RS modal-window close sprite
    -- (red stone button with gold X), ids sourced from PrettyUI's sprite map.
    -- Hides the window (tracking continues). Swaps to the hover sprite on
    -- mouseover for polish.
    local CLOSE_NML = id.Sprite.RS3_BTN_MODAL_WINDOW_1_CLOSE_NML
    local CLOSE_OVR = id.Sprite.RS3_BTN_MODAL_WINDOW_1_CLOSE_OVR
    local closeBtn = ui.Sprite.new(window)
    closeBtn:SetSize(20, 20, 0, 0)
    closeBtn:SetX(-28, 1.0)   -- 8px from the right edge (20 wide + 8)
    closeBtn:SetY(9)          -- vertically centred in the TITLE_H strip
    closeBtn.spriteID = CLOSE_NML
    try(function() closeBtn.clickthrough = false end)
    try(function() closeBtn.enabled = true end)
    closeBtn:Subscribe(ui.Hook.ONMOUSEOVER, function() closeBtn.spriteID = CLOSE_OVR end)
    closeBtn:Subscribe(ui.Hook.ONMOUSELEAVE, function() closeBtn.spriteID = CLOSE_NML end)
    closeBtn:Subscribe(ui.Hook.ONCLICK, function() UI.Hide() end)

    -- Root vertical panel below the title: [tab bar] / [table] / [button bar].
    root = ui.Panel.new(window)
    root.isVertical = true
    root.spacing = 6
    root:SetSize(-24, -(S.TITLE_H + 16), 1.0, 1.0)
    root:SetPos(12, S.TITLE_H)

    -- Floating window surface: created before the tab bar so its tab buttons
    -- and reset bar can bind to it. Its body Layer is assigned below (the
    -- vertical Panel lays children out in creation order).
    local fsurf = addSurface(nil)

    -- Region 1: tab bar - equal-width toggle buttons (control this surface).
    local tabBar = ui.Panel.new(root)
    tabBar.isVertical = false
    tabBar.spacing = 4
    tabBar:SetSize(0, S.TAB_H, 1.0, 0)
    for _, tab in ipairs(TABS) do
        local btn = ui.Button.new(tabBar)
        btn:SetSize(0, 0, 1.0, 1.0)
        btn.label = tab.label
        btn.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
        try(function() btn.canToggle = true end)
        btn:Subscribe(ui.Hook.ONBUTTONPRESSED, function() selectTab(fsurf, tab.key) end)
        fsurf.tabButtons[tab.key] = btn
    end

    -- Region 2: table - a Layer filling the middle; rows positioned manually
    -- inside it (so scrolling works). Rows/scrollbar built by renderSurface().
    local body = ui.Layer.new(root)
    body:SetSize(0, 0, 1.0, 1.0)
    fsurf.body = body

    -- Region 3: button bar - the reset button for this surface's active tab.
    buttonBar = ui.Panel.new(root)
    buttonBar.isVertical = false
    buttonBar:SetSize(0, S.BUTTON_H, 1.0, 0)
    fsurf.buttonBar = buttonBar
    resetButton = ui.Button.new(buttonBar)
    resetButton:SetSize(0, 0, 1.0, 1.0)
    resetButton.label = "Reset"
    resetButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    resetButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if fsurf.activeTab == "session" then
            Stats:ResetSession()
        elseif fsurf.activeTab == "trip" then
            Stats:ResetManualSession()
        end
        refreshList()
    end)

    -- Resize handles: thin strips on each edge + small grips at each corner,
    -- so the window resizes from any direction. Each uses the same heartbeat +
    -- global-tick grab model as drag; the edge string tells grabTick which
    -- edges follow the cursor. A visible grip marks the bottom-right corner.
    local EDGE = 6   -- edge strip thickness
    local function makeHandle(edges, setup)
        local h = ui.Rectangle.new(window)
        h.fill = true
        h.colour = S.COL_TRANSPARENT
        setup(h)
        try(function() h.clickthrough = false end)
        try(function() h.enabled = true end)
        h:Subscribe(ui.Hook.ONHOLD, function()
            if not Mouse.IsAvailable() then return end
            UI._beginGrab("resize", edges)
        end)
        return h
    end

    -- Edges (full-length strips inset from the corners).
    makeHandle("l", function(h) h:SetSize(EDGE, -2 * EDGE, 0, 1.0); h:SetPos(0, EDGE) end)
    makeHandle("t", function(h) h:SetSize(-2 * EDGE, EDGE, 1.0, 0); h:SetPos(EDGE, 0) end)
    makeHandle("b", function(h) h:SetSize(-2 * EDGE, EDGE, 1.0, 0); h:SetX(EDGE); h:SetY(-EDGE, 1.0) end)

    -- Right edge is SPLIT into a top segment (over the title/tab area) and a
    -- bottom segment (over the button bar), leaving the middle band - where
    -- the scrollbar lives - free, so dragging the scrollbar never triggers a
    -- resize. SB_TOP/SB_BOT mark the scrollbar's vertical span in window units.
    local SB_TOP = S.TITLE_H + S.TAB_H + 10   -- where the table body starts
    local SB_BOT = S.BUTTON_H + EDGE + 6       -- space reserved at the bottom
    makeHandle("r", function(h)  -- above the scrollbar
        h:SetSize(EDGE, SB_TOP - EDGE, 0, 0); h:SetX(-EDGE, 1.0); h:SetY(EDGE)
    end)
    makeHandle("r", function(h)  -- below the scrollbar
        h:SetSize(EDGE, SB_BOT, 0, 0); h:SetX(-EDGE, 1.0); h:SetY(-EDGE - SB_BOT, 1.0)
    end)

    -- Corners (square grips).
    makeHandle("lt", function(h) h:SetSize(EDGE, EDGE, 0, 0); h:SetPos(0, 0) end)
    makeHandle("rt", function(h) h:SetSize(EDGE, EDGE, 0, 0); h:SetX(-EDGE, 1.0); h:SetY(0) end)
    makeHandle("lb", function(h) h:SetSize(EDGE, EDGE, 0, 0); h:SetX(0); h:SetY(-EDGE, 1.0) end)

    -- Bottom-right corner resize handle (invisible, like the other edges).
    resizeHandle = makeHandle("rb", function(h)
        h:SetSize(S.HANDLE_SZ, S.HANDLE_SZ, 0, 0)
        h:SetX(-S.HANDLE_SZ, 1.0)
        h:SetY(-S.HANDLE_SZ, 1.0)
    end)

    selectTab(fsurf, fsurf.activeTab)

    -- Restore persisted visibility (defaults to shown).
    local vis
    local okVis = pcall(function() vis = PersistentDB:GetBool("scav_uiVisible") end)
    if okVis and vis == false then uiVisible = false end
    applyVisibility()
end

return UI
