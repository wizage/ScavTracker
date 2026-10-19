-- ScavTracker / ui / styles
--
-- Central style constants for the UI: layout dimensions (interface units) and
-- colours. Keeping these in one place makes re-theming/re-sizing easy and lets
-- multiple UI modules share a consistent look.

local Styles = {}

-- ---- Layout (interface units) ----
Styles.WIN_W         = 260   -- default window width
Styles.WIN_H         = 320   -- default window height
Styles.MIN_W         = 180   -- min width when resizing
Styles.MIN_H         = 160   -- min height when resizing
Styles.MAX_W         = 600   -- max width when resizing
Styles.MAX_H         = 700   -- max height when resizing
Styles.ROW_H         = 22    -- table row height
Styles.TITLE_H       = 38    -- title strip height (room above the tabs)
Styles.TAB_H         = 26    -- tab bar height
Styles.BUTTON_H      = 26    -- reset button bar height
Styles.HANDLE_SZ     = 14    -- bottom-right resize grip size
Styles.SB_W          = 8     -- scrollbar width
Styles.SB_PAD        = 2     -- gap between rows and scrollbar
Styles.ROW_RIGHT_PAD = Styles.SB_W + Styles.SB_PAD + 2  -- right room for the bar

-- ---- Fonts ----
Styles.FONT = id.Font.MUSEO_SANS_15PT_REGULAR

-- ---- Colours ----
Styles.COL_ROW_A    = Vector4.new(0.16, 0.14, 0.12, 1.0)  -- row stripe A
Styles.COL_ROW_B    = Vector4.new(0.22, 0.19, 0.16, 1.0)  -- row stripe B
Styles.COL_NAME     = Vector4.new(1.0, 1.0, 1.0, 1.0)     -- component name
Styles.COL_COUNT    = Vector4.new(1.0, 0.78, 0.30, 1.0)   -- count (gold)
Styles.COL_SB_TRACK = Vector4.new(0.10, 0.09, 0.08, 1.0)  -- scrollbar track
Styles.COL_SB_THUMB = Vector4.new(0.45, 0.40, 0.32, 1.0)  -- scrollbar thumb
Styles.COL_HANDLE   = Vector4.new(0.45, 0.40, 0.32, 0.9)  -- resize grip
Styles.COL_TRANSPARENT = Vector4.new(0.0, 0.0, 0.0, 0.0)  -- invisible capture surfaces

return Styles
