-- These test the STUB itself: each is a Hyprland behavior we learned the hard way while debugging on the
-- live session. Encoding them as tests documents "how Hyprland acts" and guards the stub's fidelity -- if
-- a grid test passes, it's only meaningful insofar as these hold.
local H = require("harness")
local hl = H.hl

H.scenario("behavior: focusing a nonexistent workspace creates it on the focused monitor", function()
  H.boot_bare()
  hl.dispatch(hl.dsp.focus({ workspace = "name:2a" }))
  H.expect_exists("2a")
  H.expect_active("DP-1", "2a") -- created + shown on the focused monitor
end)

H.scenario("behavior: an empty non-persistent workspace is GC'd when it stops being visible", function()
  H.boot_bare()
  hl.dispatch(hl.dsp.focus({ workspace = "name:2a" })) -- create+show 2a on DP-1
  H.expect_exists("2a")
  hl.dispatch(hl.dsp.focus({ workspace = "1" }))        -- leave it (empty) -> should vanish
  H.expect_absent("2a")
end)

H.scenario("behavior: closing the last active window falls back home before window.destroy", function()
  local Stub = require("stub.hyprland")
  H.boot_bare({ { name = "DP-1", x = 0, home = "2" } })
  local address = Stub.seed_window("2b", "DP-1")
  hl.dispatch(hl.dsp.focus({ workspace = "name:2b" }))
  local active_at_close, active_at_destroy, destroyed_workspace
  hl.on("window.close", function(window)
    active_at_close = hl.get_active_workspace().name
    destroyed_workspace = window.workspace.name
  end)
  hl.on("window.destroy", function()
    active_at_destroy = hl.get_active_workspace().name
  end)

  H.close(address)

  H.eq(active_at_close, "2b", "workspace at window.close")
  H.eq(active_at_destroy, "2", "workspace at window.destroy")
  H.eq(destroyed_workspace, "2b", "destroyed window's workspace")
  H.expect_absent("2b")
end)

H.scenario("behavior: workspace mutation must wait until window.destroy returns", function()
  local Stub = require("stub.hyprland")
  H.boot_bare({ { name = "DP-1", x = 0, home = "2" } })
  local address = Stub.seed_window("2b", "DP-1")
  local rename_ok, rename_error
  hl.on("window.destroy", function()
    rename_ok, rename_error = pcall(function()
      hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2b", name = "2a" }))
    end)
  end)

  H.close(address)

  H.eq(rename_ok, false, "workspace rename during window.destroy")
  H.assert(tostring(rename_error):match("workspace rename dispatched during window.destroy") ~= nil,
    "expected the destructor-boundary error")
end)

H.scenario("behavior: a persistent empty workspace survives when not visible", function()
  H.boot_bare()
  hl.workspace_rule({ workspace = "name:2a", persistent = true, monitor = "DP-1" })
  hl.dispatch(hl.dsp.focus({ workspace = "1" }))
  H.expect_exists("2a") -- persistent -> stays even though empty + not shown
end)

H.scenario("behavior: un-persisting an empty, non-visible workspace disposes it", function()
  H.boot_bare()
  hl.workspace_rule({ workspace = "name:2a", persistent = true, monitor = "DP-1" })
  hl.dispatch(hl.dsp.focus({ workspace = "1" }))
  hl.workspace_rule({ workspace = "name:2a", persistent = false })
  H.expect_absent("2a")
end)

H.scenario("behavior: renaming a WINDOWED workspace keeps its window (survives)", function()
  H.boot_bare()
  hl.dispatch(hl.dsp.focus({ workspace = "name:2c" }))
  H.open("2c")                                   -- a window on 2c
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2c", name = "2a" }))
  H.expect_absent("2c"); H.expect_windows("2a", 1)  -- window followed the rename
end)

H.scenario("behavior: renaming an EMPTY workspace disposes it (persistent rule is name-keyed)", function()
  H.boot_bare()
  hl.workspace_rule({ workspace = "name:2c", persistent = true, monitor = "DP-1" })
  hl.dispatch(hl.dsp.focus({ workspace = "1" }))  -- 2c empty, persistent, not visible
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2c", name = "2b" }))
  H.expect_absent("2c"); H.expect_absent("2b")    -- rename dropped persistence -> empty -> gone
end)

H.scenario("behavior: Hyprland 0.57 rejects name selectors containing only a number", function()
  local Stub = require("stub.hyprland")
  -- Given a workspace displayed as 0 with numbered ID 10.
  H.boot_bare()
  Stub.seed_window("0", "DP-1", 10)
  -- When the obsolete name:0 form is used.
  local ok = pcall(function()
    hl.dispatch(hl.dsp.workspace.move({ workspace = "name:0", monitor = "DP-2" }))
  end)
  -- Then the resolver rejects it instead of treating the display name as an address.
  H.eq(ok, false)
end)

H.scenario("behavior: a renamed numbered workspace is moved by its actual ID", function()
  local Stub = require("stub.hyprland")
  -- Given Super+0's workspace displayed as 0 but still numbered 10.
  H.boot_bare()
  Stub.seed_window("0", "DP-1", 10)
  -- When moving it by its numbered ID.
  hl.dispatch(hl.dsp.workspace.move({ workspace = "10", monitor = "DP-2" }))
  -- Then the existing workspace moves to the destination monitor.
  H.eq(H.workspaces()["0"].mon, "DP-2")
end)

H.scenario("behavior: renaming onto an existing name yields a DUPLICATE (the 2a disaster)", function()
  H.boot_bare()
  -- two windowed workspaces, 2a and 2b, both survive a rename; rename 2b -> 2a with 2a still present
  hl.dispatch(hl.dsp.focus({ workspace = "name:2a" })); H.open("2a")
  hl.dispatch(hl.dsp.focus({ workspace = "name:2b" })); H.open("2b")
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2b", name = "2a" }))
  local _, dups = H.workspaces()
  H.assert(dups["2a"], "expected the stub to model a duplicate 2a (it should, to catch the real bug)")
end)

H.scenario("behavior: window.destroy can deliver nil after the weak reference expires", function()
  -- Given a window and a listener for destruction.
  H.boot_bare()
  local address = H.open("1")
  local destroyed = "not called"
  hl.on("window.destroy", function(window) destroyed = window end)
  -- When Hyprland cannot lock the destroyed window's weak reference.
  H.close(address, true)
  -- Then Lua receives nil, not a window object.
  H.eq(destroyed, nil)
end)

H.scenario("behavior: Hyprland 0.57 rename changes display name but keeps the address", function()
  -- Given a windowed named workspace.
  H.boot_bare()
  H.open("2i")
  -- When changing its display name.
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  -- Then its addressable identity remains 2i.
  H.eq(hl.get_workspaces()[#hl.get_workspaces()].addressable_name, "2i")
end)

H.scenario("behavior: name selectors resolve the address rather than the display name", function()
  -- Given a renamed workspace whose address still says 2i.
  H.boot_bare()
  H.open("2i")
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  -- When focusing its original address.
  hl.dispatch(hl.dsp.focus({ workspace = "name:2i" }))
  -- Then it shows the renamed workspace, not a newly created empty 2i.
  H.expect_active("DP-1", "2a")
end)

H.scenario("behavior: focusing a renamed display label can create a duplicate", function()
  -- Given a workspace at address 2i displayed as 2a.
  H.boot_bare()
  H.open("2i")
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  -- When focusing name:2a, which is a different address.
  hl.dispatch(hl.dsp.focus({ workspace = "name:2a" }))
  -- Then there are two distinct workspaces displaying 2a.
  local _, duplicates = H.workspaces()
  H.eq(duplicates["2a"], true)
end)

H.scenario("behavior: repeated renames still address the original workspace key", function()
  -- Given a workspace at address 2i displayed as 2a.
  H.boot_bare()
  H.open("2i")
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2i", name = "2a" }))
  -- When renaming it again through the same address.
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2i", name = "2b" }))
  -- Then the same workspace now displays 2b.
  H.expect_windows("2b", 1)
end)

H.scenario("behavior: selecting the current workspace toggles back when back-and-forth is enabled", function()
  -- Given two windowed workspaces and the user's back-and-forth setting.
  H.boot_bare({ { name = "DP-1", x = 0 } })
  H.open("1")
  H.open("2")
  hl.config({ binds = { workspace_back_and_forth = true } })
  hl.dispatch(hl.dsp.focus({ workspace = "2" }))
  -- When a caller tries to reassert the workspace already being viewed.
  hl.dispatch(hl.dsp.focus({ workspace = "2" }))
  -- Then Hyprland interprets that as a request for the previous workspace.
  H.expect_active("DP-1", "1")
end)

H.scenario("behavior: global back-and-forth can return to a workspace on another monitor", function()
  -- Given windowed homes on two monitors and global back-and-forth enabled.
  H.boot_bare()
  H.open("1")
  H.open("2")
  hl.config({ binds = { workspace_back_and_forth = true } })
  hl.dispatch(hl.dsp.focus({ workspace = "2" }))
  -- When reselecting the active workspace on DP-2.
  hl.dispatch(hl.dsp.focus({ workspace = "2" }))
  -- Then the global previous workspace brings focus back to DP-1.
  H.expect_focused("DP-1")
end)
