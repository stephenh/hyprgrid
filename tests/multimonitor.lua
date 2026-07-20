-- Multi-monitor features: moving a whole column across monitors, moving a window (and the whole grid with
-- it) between tags, and auto-healing a split column.
local H = require("harness")
local function super_n(n) return "SUPER + code:" .. (n + 9) end

H.scenario("Super+Shift+O carries the whole focused column to the next monitor, and focus follows", function()
  H.boot()
  H.press(super_n(1)); H.open("1")   -- DP-1 shows column 1 home, with a window
  H.press("SUPER + CTRL + J"); H.open("1a") -- descend to 1a, give it a window (so it persists)
  H.press("SUPER + CTRL + K")         -- back to home "1"; column 1 = {1, 1a} on DP-1
  H.eq((H.workspaces())["1"].mon, "DP-1", "1 starts on DP-1")
  H.eq((H.workspaces())["1a"].mon, "DP-1", "1a starts on DP-1")

  H.press("SUPER + SHIFT + O")        -- move column right -> DP-2
  H.eq((H.workspaces())["1"].mon, "DP-2", "home 1 moved to DP-2")
  H.eq((H.workspaces())["1a"].mon, "DP-2", "tag 1a moved with it to DP-2")
  H.expect_focused("DP-2")            -- focus followed the column
  H.expect_no_duplicates()
end)

H.scenario("a split column auto-heals: a stray tag rejoins its column's monitor", function()
  H.boot()
  H.press(super_n(1)); H.open("1")
  H.press("SUPER + CTRL + J"); H.open("1a")   -- column 1 = {1, 1a} on DP-1
  H.press("SUPER + CTRL + K")

  -- create a split: shove 1a onto DP-2 behind the grid's back (as a stray move would)
  H.hl.dispatch(H.hl.dsp.workspace.move({ workspace = "name:1a", monitor = "DP-2" }))
  H.eq((H.workspaces())["1a"].mon, "DP-2", "1a is now split off onto DP-2")

  H.timers()                                  -- fire the debounced heal
  H.eq((H.workspaces())["1a"].mon, "DP-1", "heal pulled 1a back to column 1's monitor (majority/home)")
  H.expect_no_duplicates()
end)

H.scenario("closing a tag consolidates a split column instead of stranding it until the next login", function()
  local Stub = require("stub.hyprland")
  H.boot()
  -- The drifted layout this bug hit: column 2 (a..d) piled on DP-2 with its home, but column 1's lone tag
  -- 1c sits on a DIFFERENT monitor from its (drifted) home -- column 1 is already split.
  Stub.seed_window("2a", "DP-2"); Stub.seed_window("2b", "DP-2")
  local c2 = Stub.seed_window("2c", "DP-2"); Stub.seed_window("2d", "DP-2")
  local c1 = Stub.seed_window("1c", "DP-1")                                     -- column 1's lone tag on DP-1
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))                      -- view 2c on DP-2 (focused)
  H.hl.dispatch(H.hl.dsp.workspace.move({ workspace = "1", monitor = "DP-2" })) -- home 1 drifts onto DP-2 -> column 1 split

  H.close(c2)                                              -- close 2c (focused DP-2); tag c still held by 1c
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:1c" })) -- step over to 1c on DP-1
  H.close(c1)                                              -- close 1c -> compact 2d->2c, which must also heal the split

  H.expect_no_split()       -- column 1 rejoined one monitor (it used to stay split until relogin)
  H.expect_no_duplicates()
end)

H.scenario("Super+Ctrl+Shift+J carries the window down a tag AND lock-steps every monitor with it", function()
  local Stub = require("stub.hyprland")
  H.boot()
  -- A full tag-a row: a window in each column's tag a, on that column's own monitor.
  Stub.seed_window("1a", "DP-1")
  Stub.seed_window("2a", "DP-2")
  Stub.seed_window("3a", "HDMI-A-1")
  H.press("SUPER + CTRL + J")                                       -- bring every monitor onto tag a
  H.expect_active("DP-1", "1a"); H.expect_active("DP-2", "2a"); H.expect_active("HDMI-A-1", "3a")

  H.press("SUPER + CTRL + SHIFT + J")                               -- move the window down a tag
  H.expect_active("DP-1", "1b")                                     -- the window's column follows it...
  H.expect_active("DP-2", "2b"); H.expect_active("HDMI-A-1", "3b")  -- ...and so does every other monitor
  H.expect_windows("1b", 1); H.expect_absent("1a")                 -- the window moved; its old cell is gone
  H.expect_focused("DP-1"); H.expect_no_duplicates()
end)

H.scenario("Super+Ctrl+Shift+K carries the window up a tag AND lock-steps every monitor with it", function()
  local Stub = require("stub.hyprland")
  H.boot()
  -- A full tag-b row (windows in each column's tag b), reached by descending home -> a -> b together.
  Stub.seed_window("1b", "DP-1")
  Stub.seed_window("2b", "DP-2")
  Stub.seed_window("3b", "HDMI-A-1")
  H.press("SUPER + CTRL + J"); H.press("SUPER + CTRL + J")
  H.expect_active("DP-1", "1b"); H.expect_active("DP-2", "2b"); H.expect_active("HDMI-A-1", "3b")

  H.press("SUPER + CTRL + SHIFT + K")                               -- move the window up a tag
  H.expect_active("DP-1", "1a")                                     -- the window's column follows it...
  H.expect_active("DP-2", "2a"); H.expect_active("HDMI-A-1", "3a")  -- ...and so does every other monitor
  H.expect_windows("1a", 1); H.expect_absent("1b")
  H.expect_focused("DP-1"); H.expect_no_duplicates()
end)
