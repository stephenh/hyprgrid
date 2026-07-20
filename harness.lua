-- Test harness: boot workspace-grid.lua onto the StubHyprland, drive user scenarios, and assert on the
-- resulting compositor state. Keep assertions readable (per-monitor active workspace, per-tag window
-- counts, duplicate detection, focus) since those are what actually went wrong on the real thing.

local Stub = require("stub.hyprland")

local H = { passed = 0, failed = 0, failures = {} }
local GRID = "workspace-grid.lua"

-- ---- test registration -------------------------------------------------------
function H.scenario(name, fn)
  local ok, err = pcall(fn)
  if ok then
    H.passed = H.passed + 1
    io.write(string.format("  \27[32mok\27[0m   %s\n", name))
  else
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = { name = name, err = err }
    io.write(string.format("  \27[31mFAIL\27[0m %s\n         %s\n", name, tostring(err)))
  end
end

function H.report()
  io.write(string.format("\n%d passed, %d failed\n", H.passed, H.failed))
  return H.failed == 0
end

-- ---- driving the stub --------------------------------------------------------
-- Boot a fresh compositor with the given monitors, then load the grid onto it.
-- monitors default to a 3-monitor setup mirroring the user's (DP-1|DP-2|HDMI-A-1, left to right).
function H.boot(monitors)
  Stub.reset(monitors or {
    { name = "DP-1", x = 0 }, { name = "DP-2", x = 2560 }, { name = "HDMI-A-1", x = 5120 },
  })
  Stub.load(GRID)
end

-- Reset the compositor WITHOUT loading the grid -- for testing the stub's own modeled behaviors.
function H.boot_bare(monitors)
  Stub.reset(monitors or { { name = "DP-1", x = 0 }, { name = "DP-2", x = 2560 } })
end
H.hl = Stub.hl

H.press = Stub.press          -- H.press("SUPER + CTRL + J")
H.open = Stub.open_window     -- addr = H.open("2a")  (or H.open() -> on the focused workspace)
H.close = Stub.close_window   -- H.close(addr)
H.set_desc = Stub.set_desc    -- H.set_desc("b", "beta")   (tag/home key -> label)
H.desc = Stub.get_desc        -- H.desc("a")
H.timers = Stub.run_timers    -- fire deferred hl.timer callbacks (heal debounce)

-- Close every window currently on workspace `ws`.
function H.close_all_on(ws)
  local addrs = {}
  for _, win in ipairs(Stub.S().windows) do if win.ws == ws then addrs[#addrs + 1] = win.addr end end
  for _, a in ipairs(addrs) do H.close(a) end
end
H.add_mon = Stub.add_monitor  -- H.add_mon("DP-3", 7680)
H.rm_mon = Stub.remove_monitor

-- ---- inspecting state --------------------------------------------------------
function H.focused()
  for _, m in ipairs(Stub.hl.get_monitors()) do if m.focused then return m.name end end
end

function H.active(mon)
  for _, m in ipairs(Stub.hl.get_monitors()) do if m.name == mon then return m.active_workspace.name end end
end

-- name -> { mon=, win=, persist= }; also returns a set of duplicated names.
function H.workspaces()
  local by, dups, seen = {}, {}, {}
  for _, w in ipairs(Stub.hl.get_workspaces()) do
    if seen[w.name] then dups[w.name] = true end
    seen[w.name] = true
    by[w.name] = { mon = w.monitor.name, win = w.windows, persist = w.is_persistent }
  end
  return by, dups
end

-- ---- assertions --------------------------------------------------------------
local function fail(msg) error(msg, 3) end

function H.assert(cond, msg) if not cond then fail(msg or "assertion failed") end end

function H.eq(got, want, what)
  if got ~= want then fail(string.format("%s: got %s, want %s", what or "value", tostring(got), tostring(want))) end
end

-- The monitor `mon` shows workspace `ws`.
function H.expect_active(mon, ws) H.eq(H.active(mon), ws, mon .. " active workspace") end

-- The focused monitor is `mon`.
function H.expect_focused(mon) H.eq(H.focused(), mon, "focused monitor") end

-- No two workspaces share a name (the "duplicate 2a" class of bug).
function H.expect_no_duplicates()
  local _, dups = H.workspaces()
  local names = {}
  for n in pairs(dups) do names[#names + 1] = n end
  H.assert(#names == 0, "duplicate workspaces exist: " .. table.concat(names, ", "))
end

-- Exactly this set of grid tags exists for a column, contiguous, in order. tags e.g. {"a","b","c"}.
function H.expect_column_tags(col, tags)
  local by = H.workspaces()
  local have = {}
  for name in pairs(by) do
    local c, t = name:match("^(%d+)(%a+)$")
    if c == col then have[#have + 1] = t end
  end
  table.sort(have)
  local want = { table.unpack(tags) }; table.sort(want)
  H.eq(table.concat(have, ""), table.concat(want, ""), "column " .. col .. " tags")
end

-- No column's workspaces are spread across more than one monitor (the split-column bug).
function H.expect_no_split()
  local by, cols = H.workspaces(), {}
  for name, w in pairs(by) do
    local c = name:match("^(%d+)%a*$")
    if c then cols[c] = cols[c] or {}; cols[c][w.mon] = true end
  end
  for c, set in pairs(cols) do
    local mons = {}
    for m in pairs(set) do mons[#mons + 1] = m end
    H.assert(#mons == 1, "column " .. c .. " is split across monitors: " .. table.concat(mons, ", "))
  end
end

function H.expect_exists(ws) H.assert((H.workspaces())[ws] ~= nil, "workspace " .. ws .. " should exist") end
function H.expect_absent(ws) H.assert((H.workspaces())[ws] == nil, "workspace " .. ws .. " should NOT exist") end
function H.expect_windows(ws, n)
  local w = (H.workspaces())[ws]
  H.assert(w ~= nil, "workspace " .. ws .. " should exist")
  H.eq(w.win, n, ws .. " window count")
end

return H
