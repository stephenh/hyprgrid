local H = require("harness")
local Stub = require("stub.hyprland")
local OVERRIDE = "quattro/default/hypr/monitor-workspaces.lua"

H.scenario("Quattro moves a window to global 7 on the second monitor, not 17", function()
  -- Given a window on monitor 2 with the global-numbering override loaded.
  H.boot_bare()
  local workspaces = dofile(OVERRIDE)
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))
  H.open("2")

  -- When Omarchy's Super+Shift+7 action runs.
  H.hl.dispatch(workspaces.move_window(7))

  -- Then the window lands on global workspace 7.
  H.expect_windows("7", 1)
end)

H.scenario("Quattro's silent move keeps the current workspace visible", function()
  -- Given a window on monitor 2 with the global-numbering override loaded.
  H.boot_bare()
  local workspaces = dofile(OVERRIDE)
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))
  H.open("2")

  -- When Omarchy's silent move action sends it to workspace 8.
  H.hl.dispatch(workspaces.move_window(8, false))

  -- Then monitor 2 still shows its original workspace.
  H.expect_active("DP-2", "2")
end)

H.scenario("Quattro's silent move uses global 8, not 18", function()
  -- Given a window on monitor 2 with the global-numbering override loaded.
  H.boot_bare()
  local workspaces = dofile(OVERRIDE)
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))
  H.open("2")

  -- When Omarchy's silent move action runs.
  H.hl.dispatch(workspaces.move_window(8, false))

  -- Then the window lands on global workspace 8.
  H.expect_windows("8", 1)
end)

H.scenario("Quattro still allows explicit workspace numbers above ten", function()
  -- Given the global-numbering override on monitor 2.
  H.boot_bare()
  local workspaces = dofile(OVERRIDE)
  H.hl.dispatch(H.hl.dsp.focus({ monitor = "DP-2" }))

  -- When a caller explicitly asks for workspace 17.
  H.hl.dispatch(workspaces.focus(17))

  -- Then there is no ten-workspace limit.
  H.expect_active("DP-2", "17")
end)

H.scenario("reloading Quattro's override and hotplug keep global workspace numbers", function()
  -- Given workspace 7 has a window on monitor 2.
  H.boot_bare()
  Stub.seed_window("7", "DP-2")
  dofile(OVERRIDE)

  -- When the module loads again and a monitor arrives.
  dofile(OVERRIDE)
  H.add_mon("DP-3", 5120)
  H.timers()

  -- Then workspace 7 keeps its windows and number.
  H.expect_windows("7", 1)
end)
