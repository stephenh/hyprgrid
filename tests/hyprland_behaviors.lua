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

H.scenario("behavior: renaming onto an existing name yields a DUPLICATE (the 2a disaster)", function()
  H.boot_bare()
  -- two windowed workspaces, 2a and 2b, both survive a rename; rename 2b -> 2a with 2a still present
  hl.dispatch(hl.dsp.focus({ workspace = "name:2a" })); H.open("2a")
  hl.dispatch(hl.dsp.focus({ workspace = "name:2b" })); H.open("2b")
  hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:2b", name = "2a" }))
  local _, dups = H.workspaces()
  H.assert(dups["2a"], "expected the stub to model a duplicate 2a (it should, to catch the real bug)")
end)
