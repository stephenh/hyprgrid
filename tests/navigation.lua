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

H.scenario("MAX_ROWS=13: can descend through all 12 tags a..l, and clamps at l", function()
  H.boot()
  H.press("SUPER + code:10")            -- Super+1: focus column 1
  local reached = { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" }
  for i = 1, 12 do
    H.press("SUPER + CTRL + J")
    H.expect_active("DP-1", "1" .. reached[i])
  end
  H.press("SUPER + CTRL + J")           -- past l -> clamps, stays on l
  H.expect_active("DP-1", "1l")
end)

H.scenario("managed task without windows keeps its row during compaction", function()
  -- Given an empty managed task before a windowed task.
  H.boot()
  hyprgrid.reserve("task-one")
  H.open("2b")
  -- When pending compaction runs.
  H.timers()
  -- Then the later task retains its row.
  H.expect_windows("2b", 1)
end)

H.scenario("managed identity follows compaction after an earlier task is released", function()
  -- Given two managed tasks and a window in the second.
  H.boot()
  hyprgrid.reserve("task-one")
  hyprgrid.reserve("task-two")
  H.open("2b")
  -- When the first task is released.
  hyprgrid.release("task-one")
  H.timers()
  -- Then the second task has the first row under its original identity.
  H.eq(hyprgrid.rows["task-two"], 2)
end)

H.scenario("managed task release refuses a row with surviving windows", function()
  -- Given a managed task with an unsaved editor still open.
  H.boot()
  hyprgrid.reserve("task-one")
  H.open("1a")
  -- When release is attempted.
  pcall(hyprgrid.release, "task-one")
  -- Then its reservation remains.
  H.eq(hyprgrid.rows["task-one"], 2)
end)

H.scenario("Super+0 reaches numbered workspace 10 displayed as 0 from home 2", function()
  -- Given home 2 and the roam workspace on the same monitor.
  local Stub = require("stub.hyprland")
  H.boot({ { name = "DP-1", x = 0, home = "2" } })
  Stub.seed_window("0", "DP-1", 10)
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "2" }))
  -- When using the ordinary Super+0 shortcut.
  H.press("SUPER + code:19")
  -- Then it selects the numbered ID, regardless of its display label.
  H.eq(H.hl.get_active_workspace().id, 10)
end)

H.scenario("Super+0 falls back to roam when its matching task cell is absent", function()
  -- Given a remembered task row with no matching roam cell.
  local Stub = require("stub.hyprland")
  H.boot()
  Stub.seed_window("0", "DP-1", 10)
  Stub.seed_window("2c", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  -- When switching to the roam column.
  H.press("SUPER + code:19")
  -- Then it reaches numbered workspace 10 instead of rejecting its display name.
  H.eq(H.hl.get_active_workspace().id, 10)
end)
