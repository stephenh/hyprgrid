-- Navigation: Super+Ctrl+J/K move rows within a column; the focused monitor must never change columns.
-- (This is the class of bug where closing/navigating drifted the focused monitor onto column 3.)
local H = require("harness")

-- key helpers for the code:N binds (Super+1 == code:10, ... ; Super+Ctrl+1 jump == Super+Ctrl+code:10)
local function super_n(n) return "SUPER + code:" .. (n + 9) end
local function jump_n(n) return "SUPER + CTRL + code:" .. (n + 9) end

H.scenario("boot: three monitors on distinct homes, DP-1 focused", function()
  H.boot()
  H.expect_focused("DP-1")
  H.expect_active("DP-1", "1")
  H.expect_active("DP-2", "2")
  H.expect_active("HDMI-A-1", "3")
end)

H.scenario("Super+Ctrl+J/K walk the focused monitor down and up its own column", function()
  H.boot()
  H.press(super_n(1))            -- Super+1: focus column 1 (DP-1 already on "1")
  H.expect_focused("DP-1"); H.expect_active("DP-1", "1")
  H.press("SUPER + CTRL + J")    -- row down -> 1a
  H.expect_active("DP-1", "1a"); H.expect_focused("DP-1")
  H.press("SUPER + CTRL + J")    -- -> 1b
  H.expect_active("DP-1", "1b")
  H.press("SUPER + CTRL + K")    -- back up -> 1a
  H.expect_active("DP-1", "1a")
  H.press("SUPER + CTRL + K")    -- -> home "1"
  H.expect_active("DP-1", "1")
  H.press("SUPER + CTRL + K")    -- at home, up is a no-op; must NOT jump to another column
  H.expect_active("DP-1", "1"); H.expect_focused("DP-1")
end)

H.scenario("navigating column 1 never disturbs the column shown on DP-1's neighbor", function()
  H.boot()
  H.press("SUPER + CTRL + J")    -- DP-1 (col 1) -> 1a  (lock-step also nudges other grid columns)
  -- DP-1 stays on its own column throughout
  H.assert(H.active("DP-1"):match("^1"), "DP-1 should still show a column-1 workspace, got " .. H.active("DP-1"))
  H.expect_no_duplicates()
end)

H.scenario("MAX_ROWS=9: can descend through all 8 tags a..h, and clamps at h", function()
  H.boot()
  H.press("SUPER + code:10")            -- Super+1: focus column 1
  local reached = { "a", "b", "c", "d", "e", "f", "g", "h" }
  for i = 1, 8 do
    H.press("SUPER + CTRL + J")
    H.expect_active("DP-1", "1" .. reached[i])
  end
  H.press("SUPER + CTRL + J")           -- past h -> clamps, stays on h
  H.expect_active("DP-1", "1h")
end)
