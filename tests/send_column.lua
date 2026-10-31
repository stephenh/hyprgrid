local H = require("harness")
local Stub = require("stub.hyprland")

H.scenario("send to column 2 uses its visible task row", function()
  -- Given column 2 showing b and a window on a different home column.
  H.boot()
  Stub.seed_window("2a", "DP-2")
  Stub.seed_window("2b", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "1" }))
  H.open("1")
  -- When sending the window to column 2.
  H.press("SUPER + SHIFT + code:11")
  -- Then it joins the task instead of root 2.
  H.expect_windows("2b", 2)
end)

H.scenario("send to column 2 respects an explicit return to root 2", function()
  -- Given a previous task visit followed by root 2.
  H.boot()
  Stub.seed_window("2a", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "2" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "1" }))
  H.open("1")
  -- When sending the window to column 2.
  H.press("SUPER + SHIFT + code:11")
  -- Then the last root visit takes precedence over the remembered task tag.
  H.expect_windows("2", 1)
end)

H.scenario("send remembers a task hidden behind another column on one monitor", function()
  -- Given column 2's task hidden behind column 1.
  H.boot({ { name = "single", x = 0, home = "1" } })
  Stub.seed_window("2a", "single")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "1" }))
  H.open("1")
  -- When sending to the hidden column.
  H.press("SUPER + SHIFT + code:11")
  -- Then it returns to that column's last task.
  H.expect_windows("2a", 2)
end)

H.scenario("a hidden send destination follows row compaction", function()
  -- Given a remembered b task hidden behind column 1.
  H.boot({ { name = "single", x = 0, home = "1" } })
  Stub.seed_window("2a", "single")
  Stub.seed_window("2b", "single")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "1" }))
  H.open("1")
  -- And the preceding task closes, moving b to a.
  H.close_all_on("2a")
  H.timers()
  -- When sending to the remembered column.
  H.press("SUPER + SHIFT + code:11")
  -- Then the window joins the same task at its new row.
  H.expect_windows("2a", 2)
end)

H.scenario("switching columns falls back home when only a different tag exists", function()
  -- Given 2e is active and column 3 has a task, but no 3e.
  H.boot()
  Stub.seed_window("2e", "DP-2")
  Stub.seed_window("3a", "HDMI-A-1")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2e" }))
  -- When switching to column 3.
  H.press("SUPER + code:12")
  -- Then it visits root 3 without creating 3e.
  H.expect_active("HDMI-A-1", "3")
end)

H.scenario("switching columns visits the matching tag when it exists", function()
  -- Given matching task workspaces in columns 2 and 3.
  H.boot()
  Stub.seed_window("2e", "DP-2")
  Stub.seed_window("3e", "HDMI-A-1")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2e" }))
  -- When switching to column 3.
  H.press("SUPER + code:12")
  -- Then it visits the existing task workspace.
  H.expect_active("HDMI-A-1", "3e")
end)

H.scenario("sending from a task creates its matching destination cell", function()
  -- Given an active window in 2e with no matching cell in column 3.
  H.boot()
  Stub.seed_window("2e", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2e" }))
  H.open("2e")
  -- When sending the window to column 3.
  H.press("SUPER + SHIFT + code:12")
  -- Then it lands in the newly created 3e.
  H.expect_windows("3e", 1)
end)

H.scenario("sending to a missing task cell follows it on the destination monitor", function()
  -- Given a window in 2e and column 3 on a separate monitor.
  H.boot()
  Stub.seed_window("2e", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2e" }))
  H.open("2e")
  -- When sending to the missing 3e cell.
  H.press("SUPER + SHIFT + code:12")
  -- Then column 3's monitor shows the newly created cell.
  H.expect_active("HDMI-A-1", "3e")
end)
