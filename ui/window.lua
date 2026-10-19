-- ScavTracker / ui / window
--
-- The main plugin window: a draggable, resizable panel with three tabs
-- (Session / Trip / All Time) showing a scrollable table of component counts.
-- Built from decorative components (the interactive ui.List renders as a
-- dropdown, so rows are hand-drawn Rectangles + Text).
--
-- Style constants (sizes, colours, font) live in ui/styles, referenced as S.*.
-- Public API: UI.Init(stats), UI.Refresh(), UI.Show/Hide/Toggle/IsVisible().
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
local window
local root            -- root vertical Panel (resized with the window)
local resizeHandle    -- bottom-right resize grip
local body            -- table Layer (sized by the root panel) containing rows
local scrollCatcher   -- transparent wheel-capture surface over the table
local buttonBar       -- footer panel holding the reset button
local tabButtons = {}
local resetButton
local activeTab = "session"
local scrollY = 0
local uiVisible = true   -- window shown/hidden (persisted)

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

-- Namespace a UI persistence key with the per-account prefix from Stats, so
-- window geometry/visibility are per-account like the counters.
local function uiKey(base)
    local prefix = "scav_anon_"
    if Stats and Stats.KeyPrefix then
        local ok, p = pcall(function() return Stats:KeyPrefix() end)
        if ok and p then prefix = p end
    end
    return prefix .. base
end

-- Remove all existing row components from the table body.
local function clearRows()
    if body == nil then return end
    if type(body.DeleteAll) == "function" then
        try(function() body:DeleteAll() end)
    end
end

-- Forward declarations so earlier functions can reference these locals.
local bodyHeight, bodyWidth, refreshList, applyGeometry, saveGeometry

-- Build row i (1-based), parented to `body` with body-relative y.
-- Returns true if the row fit the visible band and was drawn.
local function buildRow(i, name, count, rarity)
    local y = (i - 1) * S.ROW_H - scrollY
    local bh = bodyHeight()

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
local grabLastTick   = 0
local grabCurTick    = 0

-- Begin (or refresh) a grab. kind = "move" | "resize" | "scroll".
-- resize: `edges` names which edges follow the cursor (l/r/t/b).
-- scroll: `scale` maps one pixel of thumb travel to scrollY units, and
--         `smax` is the max scrollY (clamp).
function UI._beginGrab(kind, edges, scale, smax)
    grabLastTick = grabCurTick
    if grabKind == kind and grabEdges == (edges or "") then return end
    grabKind = kind
    grabEdges = edges or ""
    grabBaseX, grabBaseY = winX, winY
    grabBaseW, grabBaseH = winW, winH
    grabBaseScroll = scrollY
    grabScrollScale = scale or 1
    grabScrollMax = smax or 0
    grabStartMX, grabStartMY = Mouse.GetX(), Mouse.GetY()
end

local function grabTick(e)
    grabCurTick = (e and e.logicTick) or (grabCurTick + 1)
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
        local ns = grabBaseScroll + dy * grabScrollScale
        if ns < 0 then ns = 0 elseif ns > grabScrollMax then ns = grabScrollMax end
        scrollY = ns
        refreshList()
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
function bodyHeight()
    local h
    if body ~= nil then pcall(function() h = body.height end) end
    if type(h) == "number" and h > 0 then return h end
    return winH - S.TITLE_H - S.TAB_H - S.BUTTON_H - 24
end

-- Inner width of the table Layer (for scrollbar placement).
function bodyWidth()
    local w
    if body ~= nil then pcall(function() w = body.width end) end
    if type(w) == "number" and w > 0 then return w end
    return winW - 16
end

local function visibleRowCount()
    return math.floor(bodyHeight() / S.ROW_H)
end

local function maxScroll(numRows)
    local overflow = numRows - visibleRowCount()
    if overflow <= 0 then return 0 end
    return overflow * S.ROW_H
end

-- Transparent wheel-capture surface filling the table Layer. Recreated each
-- refresh because clearRows()/DeleteAll removes it with the rows.
local function buildScrollCatcher()
    scrollCatcher = ui.Rectangle.new(body)
    scrollCatcher:SetSize(0, 0, 1.0, 1.0)
    scrollCatcher:SetPos(0, 0)
    scrollCatcher.fill = true
    scrollCatcher.colour = S.COL_TRANSPARENT
    try(function() scrollCatcher.clickthrough = false end)
    try(function() scrollCatcher.enabled = true end)
    scrollCatcher:Subscribe(ui.Hook.ONSCROLLWHEEL, function(self, delta)
        local rows = Stats:GetSorted(activeTab)
        local maxY = maxScroll(#rows)
        if maxY <= 0 then return end
        scrollY = scrollY - (delta * S.ROW_H)
        if scrollY < 0 then scrollY = 0 end
        if scrollY > maxY then scrollY = maxY end
        refreshList()
    end)
end

-- Draw the scrollbar track + thumb on the right edge of the table (only on
-- overflow). Parented to `body`; coordinates are Layer-relative.
local function buildScrollbar(numRows)
    local maxY = maxScroll(numRows)
    if maxY <= 0 then return end

    local bh = bodyHeight()
    local trackX = bodyWidth() - S.SB_W

    local track = ui.Rectangle.new(body)
    track:SetSize(S.SB_W, bh, 0, 0)
    track:SetPos(trackX, 0)
    track.fill = true
    track.colour = S.COL_SB_TRACK

    local totalContent = numRows * S.ROW_H
    local thumbH = math.max(16, math.floor(bh * (bh / totalContent)))
    local travel = bh - thumbH
    local frac = (maxY > 0) and (scrollY / maxY) or 0
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
        UI._beginGrab("scroll", nil, scale, maxY)
    end)
end

-- Rebuild the table for the active tab.
function refreshList()
    if window == nil or body == nil then return end

    -- Footer is only shown on resettable tabs. Hiding the whole bar (not just
    -- the button) lets the root Panel give that space back to the table. Done
    -- before building rows so bodyHeight() reflects the change.
    local resettable = false
    for _, tab in ipairs(TABS) do
        if tab.key == activeTab then resettable = tab.resettable end
    end
    if buttonBar ~= nil then
        try(function() buttonBar.hidden = not resettable end)
    end

    clearRows()
    buildScrollCatcher()

    local rows = Stats:GetSorted(activeTab)
    for i, row in ipairs(rows) do
        try(buildRow, i, row.name, row.count, row.rarity)
    end

    try(buildScrollbar, #rows)
end

local function selectTab(key)
    activeTab = key
    scrollY = 0
    for k, btn in pairs(tabButtons) do
        try(function() btn.isToggled = (k == key) end)  -- highlight active tab
    end
    refreshList()
end

function UI.Refresh()
    refreshList()
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

function UI.Init(statsModule, coloursModule)
    Stats = statsModule
    Colours = coloursModule

    local gameWindow = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
    if gameWindow == nil then
        print("[ScavTracker] UI: could not find plugin build layer; UI not created")
        return
    end

    -- Root window: a plain Layer (no built-in frame) so our gold sprite border
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
    -- on top. BORDER/CORNER are the frame thickness.
    local BORDER = 4
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
    -- it at its thin natural height flush against the top/bottom.
    local EDGE_T = 2
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

    -- Region 1: tab bar - equal-width toggle buttons.
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
        btn:Subscribe(ui.Hook.ONBUTTONPRESSED, function() selectTab(tab.key) end)
        tabButtons[tab.key] = btn
    end

    -- Region 2: table - a Layer filling the middle; rows positioned manually
    -- inside it (so scrolling works). Rows/scrollbar built by refreshList().
    body = ui.Layer.new(root)
    body:SetSize(0, 0, 1.0, 1.0)

    -- Region 3: button bar - the reset button for the active resettable tab.
    buttonBar = ui.Panel.new(root)
    buttonBar.isVertical = false
    buttonBar:SetSize(0, S.BUTTON_H, 1.0, 0)
    resetButton = ui.Button.new(buttonBar)
    resetButton:SetSize(0, 0, 1.0, 1.0)
    resetButton.label = "Reset"
    resetButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    resetButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        if activeTab == "session" then
            Stats:ResetSession()
        elseif activeTab == "trip" then
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

    selectTab(activeTab)

    -- Restore persisted visibility (defaults to shown).
    local vis
    local okVis = pcall(function() vis = PersistentDB:GetBool("scav_uiVisible") end)
    if okVis and vis == false then uiVisible = false end
    applyVisibility()
end

return UI
