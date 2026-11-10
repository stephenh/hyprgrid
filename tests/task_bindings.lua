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

H.scenario("promoting an unmanaged row claims its existing letter", function()
  -- Given windows in two columns of unmanaged row c.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("1c", "DP-1")
  local window = Stub.seed_window("2c", "DP-2")
  -- When promoting that row instead of allocating a free slot.
  hyprgrid.adopt("promoted", window)
  -- Then the managed task owns c, not the first empty row a.
  H.eq(hyprgrid.rows.promoted, 4)
end)

H.scenario("promotion leaves the existing terminal in place", function()
  -- Given an unmanaged row with windows on separate monitors.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("1b", "DP-1")
  local window = Stub.seed_window("2b", "DP-2")
  -- When promoting it.
  hyprgrid.adopt("promoted", window)
  -- Then its terminal remains in the original workspace.
  H.expect_windows("2b", 1)
end)

H.scenario("promotion cannot steal another managed task's row", function()
  -- Given a managed row with an existing window.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.reserve("owner")
  local window = Stub.seed_window("2a", "DP-2")
  -- When another task attempts to adopt its row.
  local success = pcall(hyprgrid.adopt, "promoted", window)
  -- Then the adoption is rejected.
  H.eq(success, false)
end)

H.scenario("promotion rejects a window closed while the menus were open", function()
  -- Given an unmanaged row whose representative window has closed.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local window = Stub.seed_window("2a", "DP-2")
  local address = window
  H.close(window)
  H.timers()
  -- When the stale promotion request arrives.
  local success = pcall(hyprgrid.adopt, "promoted", address)
  -- Then it does not adopt a now-empty or reused letter.
  H.eq(success, false)
end)

H.scenario("promotion does not turn a home workspace into a task", function()
  -- Given a terminal on a home workspace.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local window = Stub.seed_window("2", "DP-2")
  -- When attempting promotion.
  local success = pcall(hyprgrid.adopt, "promoted", window)
  -- Then no home row is registered as a task.
  H.eq(success, false)
end)

H.scenario("newly promoted row actions use its task ID before background registration finishes", function()
  -- Given focus on an unmanaged row's terminal workspace.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2b", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  -- When opening task actions.
  H.press("SUPER + T")
  H.press("space")
  -- Then actions address the ID assigned by the prefix, without waiting for Python.
  local id = next(hyprgrid.rows)
  H.eq(Stub.S().log[#Stub.S().log], "exec:hyprgrid-task menu actions --task " .. tostring(id))
end)

H.scenario("promotion persists the existing letter across reload", function()
  -- Given an unmanaged row and a persistent assignment file.
  local path = os.tmpname()
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  local window = Stub.seed_window("3c", "HDMI-A-1")
  -- When promoting it and reloading the adapter.
  hyprgrid.adopt("promoted", window)
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  os.remove(path)
  -- Then the managed task still owns c.
  H.eq(hyprgrid.rows.promoted, 4)
end)

H.scenario("promotion does not focus the promoted row", function()
  -- Given work focused on another monitor while a promotion menu is open.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local window = Stub.seed_window("3c", "HDMI-A-1")
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-1" }))
  -- When completing promotion of c.
  hyprgrid.adopt("promoted", window)
  -- Then focus remains where the user left it.
  H.expect_focused("DP-1")
end)

H.scenario("Super+T promotes the current row while entering the submap", function()
  -- Given an unmanaged terminal workspace.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2b", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then its row is immediately assigned a task identity.
  H.eq(select(2, next(hyprgrid.rows)), 3)
end)

H.scenario("automatic promotion still leaves the task submap active", function()
  -- Given an unmanaged grid workspace.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:1a" }))
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then the next key still selects a task action.
  H.eq(Stub.S().submap, "hyprgrid-tasks")
end)

H.scenario("automatic promotion also supports an empty active grid workspace", function()
  -- Given an empty grid cell with no representative window.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then that row is still registered in place.
  H.eq(select(2, next(hyprgrid.rows)), 4)
end)

H.scenario("repeated task prefixes preserve the same task identity", function()
  -- Given a row promoted by the task prefix.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2b", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  H.press("SUPER + T")
  local id = next(hyprgrid.rows)
  -- When canceling task mode and entering it again.
  H.press("Escape")
  H.press("SUPER + T")
  -- Then the original ID still owns the row.
  H.eq(hyprgrid.rows[id or "missing"], 3)
end)

H.scenario("entering task mode at home does not promote a home workspace", function()
  -- Given focus on the home row.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then no task is created.
  H.eq(next(hyprgrid.rows), nil)
end)

H.scenario("automatic promotion queues metadata without opening a menu or an agent", function()
  -- Given an unmanaged row with existing windows.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2b", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then only the row's background metadata command is launched.
  H.eq(Stub.S().log[#Stub.S().log], "exec:hyprgrid-task ensure-task " .. tostring(next(hyprgrid.rows)))
end)

H.scenario("organize packs sparse i and j rows into a and b", function()
  -- Given two surviving rows with gaps before them.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  -- When explicitly organizing the grid.
  hyprgrid.organize()
  -- Then the surviving rows are consecutive and keep their original order.
  H.expect_column_tags("2", { "a", "b" })
end)

H.scenario("organize keeps managed identity while renumbering its row", function()
  -- Given two managed rows with windows in different columns.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.claim("first", "i")
  hyprgrid.claim("second", "j")
  Stub.seed_window("1i", "DP-1")
  Stub.seed_window("2j", "DP-2")
  -- When organizing all columns together.
  hyprgrid.organize()
  -- Then the second task keeps its identity at b.
  H.eq(hyprgrid.rows.second, 3)
end)

H.scenario("organize follows the viewed task to its new letter", function()
  -- Given focus on the later sparse row.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2j" }))
  -- When organizing the grid.
  hyprgrid.organize()
  -- Then the same task remains visible under its new letter.
  H.expect_active("DP-2", "2b")
end)

H.scenario("organize does not duplicate the active workspace name", function()
  -- Given a sparse row visible while lower letters are empty.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2i" }))
  -- When organizing the viewed workspace.
  hyprgrid.organize()
  -- Then parking and renaming never leave duplicate names.
  H.expect_no_duplicates()
end)

H.scenario("organize preserves other monitors' viewed tasks when invoked from home", function()
  -- Given different task rows visible on two monitors, with focus on a third monitor's home.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("1i", "DP-1")
  Stub.seed_window("2j", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:1i" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2j" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "3" }))
  -- When organizing from home.
  hyprgrid.organize()
  -- Then the second monitor follows its own viewed task, rather than being sent home.
  H.expect_active("DP-2", "2b")
end)

H.scenario("organize keeps focus on the original home workspace", function()
  -- Given a task visible elsewhere while the home workspace is focused.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2i" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "3" }))
  -- When organizing.
  hyprgrid.organize()
  -- Then focus stays on the home monitor.
  H.expect_focused("HDMI-A-1")
end)

H.scenario("organize preserves empty managed task reservations", function()
  -- Given a task without windows before another task's terminal.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.claim("empty", "i")
  Stub.seed_window("2j", "DP-2")
  -- When organizing the grid.
  hyprgrid.organize()
  -- Then the empty task still owns a row instead of being discarded.
  H.eq(hyprgrid.rows.empty, 2)
end)

H.scenario("organize does not turn automatic compaction back on", function()
  -- Given a manually organized grid.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local first = Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  hyprgrid.organize()
  -- When a lower row subsequently closes.
  H.close(first)
  H.timers()
  -- Then the remaining row keeps its new letter until another explicit organize.
  H.expect_windows("2b", 1)
end)

H.scenario("organize carries unmanaged descriptions to the new letters", function()
  -- Given descriptions for two sparse rows.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  H.set_desc("i", "Invoices")
  H.set_desc("j", "Reports")
  -- When organizing them.
  hyprgrid.organize()
  -- Then the later row's description follows it to b.
  H.eq(H.desc("b"), "Reports")
end)

H.scenario("organize retains descriptions for rows that do not move", function()
  -- Given a row already at a and another row separated by gaps.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2a", "DP-2")
  Stub.seed_window("2i", "DP-2")
  H.set_desc("a", "Invoices")
  H.set_desc("i", "Reports")
  -- When rebuilding the description map during organize.
  hyprgrid.organize()
  -- Then the unchanged row's description is not lost.
  H.eq(H.desc("a"), "Invoices")
end)

H.scenario("a pending Zed launch follows its task through organize", function()
  -- Given an editor launch captured before its row is renumbered.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  hyprgrid.claim("editor", "i")
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2i" }))
  hyprgrid.prepare_zed("editor", "repo")
  -- When organizing before Zed maps on another workspace.
  hyprgrid.organize()
  H.open("1", "dev.zed.Zed", "repo")
  H.timers()
  -- Then the editor reaches its original task under the new letter.
  H.expect_windows("2a", 2)
end)

H.scenario("Super+T o exits the submap and requests organization", function()
  -- Given the task prefix.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  H.press("SUPER + T")
  -- When selecting organize.
  H.press("o")
  -- Then the coordinator serializes it with task lifecycle operations.
  H.eq(Stub.S().log[#Stub.S().log], "exec:hyprgrid-task organize")
end)

H.scenario("organized task letters persist across adapter reloads", function()
  -- Given a sparse managed task and a persistent assignment file.
  local path = os.tmpname()
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  hyprgrid.claim("survivor", "i")
  Stub.seed_window("2i", "DP-2")
  -- When organizing and reloading the adapter.
  hyprgrid.organize()
  H.boot()
  loadfile("task-workspaces.lua")()({ path = path })
  os.remove(path)
  -- Then the same task retains its new letter a.
  H.eq(hyprgrid.rows.survivor, 2)
end)

H.scenario("a queued close event cannot override organize's restored task", function()
  -- Given a close event still queued for a sparse row that has just emptied.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local closed = Stub.seed_window("2h", "DP-2")
  Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2h" }))
  H.close(closed)
  -- And the user now viewing i before that deferred callback runs.
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2i" }))
  -- When organizing and then processing the old close callback.
  hyprgrid.organize()
  H.timers()
  -- Then the selected task stays visible, rather than following the obsolete h cell.
  H.expect_active("DP-2", "2a")
end)

H.scenario("organize keeps workspace addresses aligned with grid labels", function()
  -- Given sparse grid cells on Hyprland 0.57, where rename cannot change their addresses.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  Stub.seed_window("2j", "DP-2")
  -- When organizing the rows.
  hyprgrid.organize()
  -- Then every surviving named cell has the address its navigation selector will use.
  for _, workspace in ipairs(H.hl.get_workspaces()) do
    if workspace.name:match("^%d+[a-l]$") then H.eq(workspace.addressable_name, workspace.name) end
  end
end)

H.scenario("navigation after organize does not recreate the old selector address", function()
  -- Given a task organized from i to a.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2i" }))
  hyprgrid.organize()
  -- When leaving and returning to a through ordinary navigation.
  H.press("SUPER + CTRL + J")
  H.press("SUPER + CTRL + K")
  -- Then there is still only one workspace displaying each grid label.
  H.expect_no_duplicates()
end)

H.scenario("organize rejects an already renamed grid before changing anything else", function()
  -- Given a legacy organize result with mismatched address and display name.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  -- When organization is requested again.
  local ok = pcall(hyprgrid.organize)
  -- Then it refuses instead of compounding the corrupted layout.
  H.eq(ok, false)
end)

H.scenario("workspace walking can reach distinct workspaces with duplicate display labels", function()
  -- Given two existing workspaces with the same displayed label but different addresses.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2f", "DP-2")
  Stub.seed_window("2j", "DP-2")
  H.hl.dispatch(H.hl.dsp.workspace.rename({ workspace = "name:2f", name = "2e" }))
  H.hl.dispatch(H.hl.dsp.workspace.rename({ workspace = "name:2j", name = "2e" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2f" }))
  -- When walking to the next existing workspace.
  H.press("SUPER + CTRL + L")
  -- Then it selects the other real address, not a third empty workspace called 2e.
  H.eq(H.hl.get_active_workspace().addressable_name, "2j")
end)

H.scenario("automatic healing does not rearrange an already corrupted grid", function()
  -- Given a renamed grid cell and another cell on a different monitor.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2i", "DP-2")
  H.hl.dispatch(H.hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  Stub.seed_window("2b", "HDMI-A-1")
  -- When a monitor event queues the normal split healer.
  Stub.add_monitor("DP-3", 7680)
  H.timers()
  -- Then it leaves the existing monitor placements alone for deliberate recovery.
  H.eq(H.workspaces()["2b"].mon, "HDMI-A-1")
end)

H.scenario("a second organize preserves window identity after another gap opens", function()
  -- Given two window groups already organized once.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  local first = Stub.seed_window("2i", "DP-2")
  local second = Stub.seed_window("2j", "DP-2")
  hyprgrid.organize()
  -- And a later row, with the first group now closed.
  Stub.seed_window("2f", "DP-2")
  H.close(first)
  H.timers()
  -- When organizing a second time.
  hyprgrid.organize()
  -- Then the original second window is reachable at the new canonical a address.
  for _, window in ipairs(H.hl.get_windows()) do
    if window.address == second then H.eq(window.workspace.addressable_name, "2a") end
  end
end)

H.scenario("an invalid navigation target is rejected before changing monitor focus", function()
  -- Given a windowed 2b at address 2c and an empty duplicate on another monitor.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2c", "DP-2")
  H.hl.dispatch(H.hl.dsp.workspace.rename({ workspace = "name:2c", name = "2b" }))
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "HDMI-A-1" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2b" }))
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2c" }))
  -- When a row jump would reuse address 2c for a different label.
  pcall(function() H.press("SUPER + CTRL + J") end)
  -- Then the rejected jump does not strand focus on the duplicate's monitor.
  H.expect_focused("DP-2")
end)

H.scenario("the task submap has no manual column-healing shortcut", function()
  -- Given the task adapter.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  -- When entering task mode.
  H.press("SUPER + T")
  -- Then monitor healing needs no task action.
  H.eq(Stub.S().binds["hyprgrid-tasks:m"], nil)
end)

H.scenario("ordinary row navigation reaches c from b after organization", function()
  -- Given three sparse window groups and no managed reservations.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2a", "DP-1")
  Stub.seed_window("2f", "DP-1")
  Stub.seed_window("2i", "DP-1")
  H.hl.dispatch(H.hl.dsp.focus({ workspace = "name:2f" }))
  -- When organizing f to b, then navigating normally to the following row.
  hyprgrid.organize()
  H.press("SUPER + CTRL + J")
  -- Then the original i group is reachable through the canonical c address.
  H.eq(H.hl.get_active_workspace().addressable_name, "2c")
end)

H.scenario("automatic majority healing still runs after organization", function()
  -- Given three organized window groups on DP-1.
  H.boot()
  loadfile("task-workspaces.lua")()({ path = false })
  Stub.seed_window("2a", "DP-1")
  Stub.seed_window("2f", "DP-1")
  Stub.seed_window("2i", "DP-1")
  hyprgrid.organize()
  -- When one group drifts after organization and the move handler runs.
  H.hl.dispatch(H.hl.dsp.workspace.move({ workspace = "name:2c", monitor = "DP-2" }))
  H.timers()
  -- Then c automatically rejoins its column on DP-1.
  H.eq(H.workspaces()["2c"].mon, "DP-1")
end)
