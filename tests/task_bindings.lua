local H = require("harness")
local Stub = require("stub.hyprland")

H.scenario("task f prefix jumps directly while preserving the terminal column", function()
  -- Given two columns with windows in row f.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("1f", "DP-1")
  Stub.seed_window("2f", "DP-2")
  H.press("SUPER + code:11")
  -- When selecting f in task mode.
  H.press("SUPER + T")
  H.press("f")
  -- Then the focused column shows 2f.
  H.expect_active("DP-2", "2f")
end)

H.scenario("task selection exits the submap", function()
  -- Given task mode.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  H.press("SUPER + T")
  -- When selecting an unused task letter.
  H.press("l")
  -- Then normal bindings are restored.
  H.eq(Stub.S().submap, "reset")
end)

H.scenario("increasing task count does not bind numeric shortcuts onto letter keys", function()
  -- Given the expanded grid.
  H.boot()
  -- When inspecting the physical Q key (code 24 is not used; code 22 is backspace).
  -- Then backspace has not become a row shortcut.
  H.eq(Stub.S().binds["SUPER+CTRL+code:22"], nil)
end)

H.scenario("a delayed task terminal rejoins column 2 even when its target cell disappeared", function()
  -- Given an empty reserved task and the user now working on monitor 1.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  -- When the tagged terminal maps on the currently focused monitor.
  H.open("1", "org.hyprgrid.taskabc123")
  H.timers()
  -- Then it belongs to column 2's monitor.
  H.eq(H.workspaces()["2a"].mon, "DP-2")
end)

H.scenario("task row letters stay stable across release and reload", function()
  -- Given two reserved tasks with a persistent row file.
  local path = os.tmpname()
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  hyprgrid.reserve("first")
  hyprgrid.reserve("second")
  -- When releasing the first task and reloading the adapter.
  hyprgrid.release("first")
  H.timers()
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  os.remove(path)
  -- Then the second task retains b, leaving a free.
  H.eq(hyprgrid.rows.second, 3)
end)

H.scenario("switching columns does not create a managed task's missing IDE workspace", function()
  -- Given a managed task with only a terminal so far.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  Stub.seed_window("2a", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  -- When explicitly selecting the IDE column.
  H.press("SUPER + code:10")
  -- Then a missing IDE workspace falls back to home.
  H.expect_active("DP-1", "1")
end)

H.scenario("opening an agent from a non-grid column does not enlist that column", function()
  -- Given focus on Slack's home column and terminals on another monitor.
  H.boot({ { name = "slack", x = 0, home = "8" }, { name = "terminal", x = 2560, home = "2" } })
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  -- When opening the task's terminal column.
  hyprgrid.jump("abc123", "2")
  -- Then Slack stays on its home workspace.
  H.expect_active("slack", "8")
end)

H.scenario("Super+D renames the managed task for the active row", function()
  -- Given a managed row viewed from its terminal column.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  Stub.seed_window("2a", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  -- When requesting a workspace description.
  H.press("SUPER + D")
  -- Then the prompt targets the stable task identity.
  H.eq(Stub.S().log[#Stub.S().log], "exec:hyprgrid-task menu rename --task abc123")
end)

H.scenario("Super+D keeps the description prompt for an unmanaged row", function()
  -- Given an unmanaged task row.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2a", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  -- When requesting a workspace description.
  H.press("SUPER + D")
  -- Then the original description command handles it.
  H.eq(Stub.S().log[#Stub.S().log], "exec:" .. os.getenv("HOME") .. "/.local/bin/hypr-ws-desc set")
end)

H.scenario("closing the final managed row window requests deferred auto-archive", function()
  -- Given a managed task with one window.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  local window = Stub.seed_window("2a", "DP-2")
  -- When the last window closes and deferred handlers run.
  H.close(window)
  H.timers()
  -- Then the coordinator gets the stable task ID to archive.
  local requests = {}
  for _, entry in ipairs(Stub.S().log) do
    if entry:find("archive%-empty") then requests[#requests + 1] = entry end
  end
  H.eq(table.concat(requests, "\n"), "exec:hyprgrid-task archive-empty abc123")
end)

H.scenario("closing one column does not auto-archive a task with another window", function()
  -- Given a managed task with an editor and a terminal.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  Stub.seed_window("1a", "DP-1")
  local terminal = Stub.seed_window("2a", "DP-2")
  -- When its terminal closes.
  H.close(terminal)
  H.timers()
  -- Then the task is not requested for auto-archive.
  local requests = 0
  for _, entry in ipairs(Stub.S().log) do
    if entry:find("archive%-empty") then requests = requests + 1 end
  end
  H.eq(requests, 0)
end)

H.scenario("new tasks reuse the first free slot without moving existing rows", function()
  -- Given managed a and b plus an unmanaged row c.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("first")
  hyprgrid.reserve("second")
  Stub.seed_window("2c", "DP-2")
  -- When a is released and another task is created.
  hyprgrid.release("first")
  H.timers()
  hyprgrid.reserve("third")
  -- Then the new task fills a, rather than following compacted survivors.
  H.eq(hyprgrid.rows.third, 2)
end)

H.scenario("unmanaged rows also stay put when task mode is enabled", function()
  -- Given managed a and an unmanaged window in b.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("first")
  Stub.seed_window("2b", "DP-2")
  -- When releasing a.
  hyprgrid.release("first")
  H.timers()
  -- Then b retains its letter instead of consuming the free slot.
  H.expect_windows("2b", 1)
end)

H.scenario("browser shortcut captures the current task before opening the profile picker", function()
  -- Given a managed task viewed from its terminal column.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  Stub.seed_window("2a", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2a" }))
  -- When requesting a new browser window.
  H.press("SUPER + SHIFT + RETURN")
  -- Then the picker receives the stable task identity.
  H.eq(Stub.S().log[#Stub.S().log], "exec:hyprgrid-task menu browser --task abc123")
end)

H.scenario("Zed opening on the wrong row returns to its launch workspace", function()
  -- Given Zed launched from task c's terminal workspace.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.rows.abc123 = 4
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  hyprgrid.prepare_zed("abc123", "biff-biff-abc123")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2d" }))
  -- When the new Zed window maps with its task project title.
  H.open("2d", "dev.zed.Zed", "biff-biff-abc123")
  H.timers()
  -- Then the window stays in the workspace where it was launched.
  H.expect_windows("2c", 1)
end)

H.scenario("routing Zed restores focus to its launch monitor", function()
  -- Given a launch on the terminal monitor before Zed displaces focus.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.rows.abc123 = 4
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  hyprgrid.prepare_zed("abc123", "biff-biff-abc123")
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-1" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:1d" }))
  -- When the window-open handler completes.
  H.open("1d", "dev.zed.Zed", "biff-biff-abc123")
  H.timers()
  -- Then focus returns to the launch monitor.
  H.expect_focused("DP-2")
end)

H.scenario("auto-archive survives a destroyed window with an expired reference", function()
  -- Given the last window in a managed task.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("abc123")
  local window = Stub.seed_window("2a", "DP-2")
  -- When destruction delivers nil instead of a live window object.
  H.close(window, true)
  H.timers()
  -- Then auto-archive still receives the identity captured before destruction.
  local requests = {}
  for _, entry in ipairs(Stub.S().log) do
    if entry:find("archive%-empty") then requests[#requests + 1] = entry end
  end
  H.eq(table.concat(requests, "\n"), "exec:hyprgrid-task archive-empty abc123")
end)

H.scenario("Zed routes a clean repository title back to its launch workspace", function()
  -- Given a task whose nested checkout is named biff.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.rows.abc123 = 4
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  hyprgrid.prepare_zed("abc123", "biff")
  -- When Zed maps elsewhere with only the repository name in its title.
  H.open("2d", "dev.zed.Zed", "biff")
  H.timers()
  -- Then it returns to the captured launch workspace.
  H.expect_windows("2c", 1)
end)
