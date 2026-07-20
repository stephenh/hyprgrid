-- 2D workspace grid on top of Hyprland. Two kinds of workspace:
--   home workspaces = the numbered 1..9, one per "home column" (Super+1..9 is an Omarchy default)
--   grid workspaces = "2a","2b",... : a home column ("2") plus an a/b/c/d "tag" suffix
-- This file adds the vertical axis (the tags), cross-monitor tag lock-step, and per-tag labels.
--
-- Lock-step: monitors showing grid workspaces move together across tags -- driving one monitor from
-- 2a -> 2b takes another monitor from 3a -> 3b, but a monitor on a home workspace whose column has no
-- grid workspaces (e.g. "8" with no 8*) is left alone. The focused monitor always moves, so you can
-- create the first tag of a fresh column.
--
-- Descriptions (waybar, via ~/.local/bin/hypr-ws-desc): a monitor on a home workspace shows that
-- home workspace's own label (1=ide, 2=terminal, 3=personal); a monitor on a grid workspace shows
-- the tag's shared label (every *a alike, e.g. "bug-one"; every *b alike, e.g. "bug-two").

local MAX_ROWS = 9 -- row 1 is the home workspace; rows 2..9 are tags a..h (8 tags). Bump for more tags.

-- True while set_all_to_row / reconcile_tags is driving monitors, so nested focus churn doesn't recurse.
local syncing = false
local reconciling = false

-- True while heal_split_columns is moving workspaces (stops its own moves from re-triggering it) and
-- while move_column_to_monitor is intentionally relocating a whole column (stops healing from fighting
-- the in-progress move, which is transiently "split" until every workspace has landed).
local healing = false
local relocating = false

-- The tag row last visited (>=2), remembered so Super+N can return to it even after a home-workspace
-- detour; nil until a grid workspace is focused. Home visits deliberately do not clear it.
local current_row = nil

-- Parse a workspace name into (home column, row). Row 1 is the home workspace; rows 2+ are grid
-- workspaces (row 2 = tag "a"). I.e. "2b" -> ("2", 3), "2" -> ("2", 1); nil if neither home nor grid.
local function cell_of(name)
  local col, tag = (name or ""):match("^(%d+)(%a*)$")
  if not col then return nil end -- not a home/grid ws (e.g. special:scratchpad)
  return col, (tag ~= "" and tag:byte(1) - string.byte("a") + 2) or 1
end

-- Home column, row of the focused monitor's workspace. I.e. "2b" -> ("2", 3).
local function current_cell()
  local ws = hl.get_active_workspace()
  return cell_of(ws and ws.name)
end

-- Bare workspace name for a home column + row. I.e. ("2",1) -> "2" (home ws), ("2",3) -> "2b".
local function ws_name_for(col, row)
  if row <= 1 then return col end
  return col .. string.char(string.byte("a") + row - 2)
end

-- Workspace selector for a home column + row. I.e. ("2",1) -> "2" (home ws), ("2",3) -> "name:2b".
local function selector_for(col, row)
  if row <= 1 then return col end
  return "name:" .. ws_name_for(col, row)
end

-- Name of the focused monitor. I.e. "DP-2".
local function focused_monitor()
  for _, m in ipairs(hl.get_monitors()) do
    if m.focused then return m.name end
  end
end

-- Name of the monitor immediately left/right of the focused one, ordered by x position. dir "l"/"r";
-- nil at the edge of the layout (no wrap). I.e. focused DP-2 -> "DP-1" for "l", "HDMI-A-1" for "r".
local function adjacent_monitor(dir)
  local mons = hl.get_monitors()
  table.sort(mons, function(a, b) return a.x < b.x end)
  local idx
  for i, m in ipairs(mons) do
    if m.focused then idx = i end
  end
  if not idx then return nil end
  local neighbor = mons[idx + (dir == "l" and -1 or 1)]
  return neighbor and neighbor.name or nil
end

-- Name of the monitor currently hosting home column `col` (all its workspaces share one). I.e. "1" -> "DP-1".
local function column_monitor(col)
  for _, ws in ipairs(hl.get_workspaces()) do
    if cell_of(ws.name) == col and ws.monitor then return ws.monitor.name end
  end
end

-- Whether a workspace with this exact name currently exists. I.e. "1c" -> true only once created.
local function workspace_exists(name)
  for _, ws in ipairs(hl.get_workspaces()) do
    if ws.name == name then return true end
  end
  return false
end

-- Tag letter for a grid row. I.e. 2 -> "a", 3 -> "b", 5 -> "d".
local function tag_of(row) return string.char(string.byte("a") + row - 2) end

-- Home columns that currently have at least one grid workspace. I.e. -> { ["2"] = true } when 2a exists.
local function grid_columns()
  local cols = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    local col = (ws.name or ""):match("^(%d+)%a+$")
    if col then cols[col] = true end
  end
  return cols
end

-- Consolidate any split column onto a single monitor: the one already holding most of its workspaces,
-- ties broken toward the home workspace's monitor. Whichever piece drifted -- a stray tag, or the home
-- itself after a resume reshuffles outputs -- rejoins the pack instead of the pack chasing it. (A split
-- otherwise makes the lock-step focus a tag on another screen, bouncing focus off the monitor you're on
-- and dropping waybar's active underline.) No-op when nothing is split; focus is left where it was.
local function heal_split_columns()
  if healing or relocating then return end
  healing = true
  local origin = focused_monitor()
  -- Per column: how many of its workspaces sit on each monitor, and which monitor holds its home.
  local counts, home_mon = {}, {}
  for _, ws in ipairs(hl.get_workspaces()) do
    local col, row = cell_of(ws.name)
    if col and ws.monitor then
      counts[col] = counts[col] or {}
      counts[col][ws.monitor.name] = (counts[col][ws.monitor.name] or 0) + 1
      if row == 1 then home_mon[col] = ws.monitor.name end
    end
  end
  -- Anchor each column to its majority monitor (home's monitor wins ties).
  local anchor = {}
  for col, per_mon in pairs(counts) do
    local best, best_n
    for m, n in pairs(per_mon) do
      if not best or n > best_n or (n == best_n and m == home_mon[col]) then best, best_n = m, n end
    end
    anchor[col] = best
  end
  for _, ws in ipairs(hl.get_workspaces()) do
    local col, row = cell_of(ws.name)
    if col and ws.monitor and anchor[col] and ws.monitor.name ~= anchor[col] then
      hl.dispatch(hl.dsp.workspace.move({ workspace = selector_for(col, row), monitor = anchor[col] }))
    end
  end
  if origin then hl.dispatch(hl.dsp.focus({ monitor = origin })) end
  healing = false
end

-- Coalesce a burst of monitor/move events (e.g. a resume reshuffles many workspaces at once) into one
-- heal shortly after, rather than fighting each intermediate move. Leading-edge: the first event arms an
-- 800ms one-shot; further events re-arm it once it has fired, so a still-settling layout converges.
local heal_scheduled = false
local function schedule_heal()
  if heal_scheduled then return end
  heal_scheduled = true
  hl.timer(function() heal_scheduled = false; heal_split_columns() end, { timeout = 800, type = "oneshot" })
end

-- Move the focused monitor -- plus every other monitor whose home column already has grid workspaces
-- -- to row R of its own column, restoring focus to where it started. A monitor on a home workspace
-- whose column has no grid workspaces (e.g. "8" with no 8*) is left alone, so it isn't dragged into
-- the grid; the focused monitor still moves so you can create the first tag of a fresh column.
-- Guarded by `syncing` so the empty workspaces we move off of don't trigger a compaction mid-sync.
local function set_all_to_row(R)
  local origin = focused_monitor()
  local origin_col = current_cell()
  local cols = grid_columns()
  syncing = true
  -- Lock-step the OTHER monitors first. A split column's home workspace lives on a different monitor, so
  -- focusing it bounces focus across monitors; doing all that before the focused monitor means the bounce
  -- can't leave the focused monitor stranded on the wrong workspace.
  for _, mon in ipairs(hl.get_monitors()) do
    if mon.name ~= origin then
      local col = cell_of(mon.active_workspace and mon.active_workspace.name)
      if col and cols[col] then
        hl.dispatch(hl.dsp.focus({ monitor = mon.name }))
        hl.dispatch(hl.dsp.focus({ workspace = selector_for(col, R) }))
      end
    end
  end
  -- Move the focused monitor strictly LAST, re-asserting its workspace explicitly (not just re-focusing
  -- the monitor). Nothing runs after this, so Super+Ctrl+J/K can never drift it off its own column.
  if origin and origin_col then
    hl.dispatch(hl.dsp.focus({ monitor = origin }))
    hl.dispatch(hl.dsp.focus({ workspace = selector_for(origin_col, R) }))
  end
  syncing = false
end

-- Row-wise tag compaction. A tag row is "occupied" if any column holds a window in it. When a lower tag
-- row empties, squeeze it out and renumber the higher tags down (c->b, d->c) ACROSS ALL COLUMNS at once,
-- and shift the shared per-tag descriptions to match (if b was "beta" and b->a, tag a becomes "beta").
--
-- Renaming a windowed workspace carries its windows, but renaming onto a name that is still on screen makes
-- a DUPLICATE (the "two 2a" bug). So we first PARK every monitor on its home column -- now no grid cell is
-- visible, the empty ones dispose, and the renames below have free targets -- then bring the monitors back
-- onto the (now compacted) tag they were on. Runs on window open/close.
local function reconcile_tags()
  if reconciling then return end
  reconciling = true

  -- occupied rows and their packed (contiguous) targets
  local occ = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    local col, row = cell_of(ws.name)
    if col and row and row >= 2 and (ws.windows or 0) > 0 then occ[row] = true end
  end
  local orows = {}
  for r in pairs(occ) do orows[#orows + 1] = r end
  table.sort(orows)
  local newrow, top, changed = {}, 1, false
  for i, r in ipairs(orows) do newrow[r] = i + 1; top = i + 1; if newrow[r] ~= r then changed = true end end
  if not changed then reconciling = false; return end -- already contiguous from tag a; nothing to squeeze

  local origin = focused_monitor()
  local _, frow = current_cell()

  -- park every monitor on its home column so no grid cell stays visible during the renames
  syncing = true
  for _, m in ipairs(hl.get_monitors()) do
    local col = cell_of(m.active_workspace and m.active_workspace.name)
    if col then
      hl.dispatch(hl.dsp.focus({ monitor = m.name }))
      hl.dispatch(hl.dsp.focus({ workspace = col }))
    end
  end

  -- renumber the windowed survivors down, ascending so each target row is already vacated; empty cells at
  -- these rows just dispose on rename (they carry no windows). Collect the tag remap for the descriptions.
  local remap = {}
  for _, r in ipairs(orows) do
    if newrow[r] ~= r then
      for _, ws in ipairs(hl.get_workspaces()) do
        local c, row = cell_of(ws.name)
        if row == r then
          hl.dispatch(hl.dsp.workspace.rename({ workspace = "name:" .. ws.name, name = ws_name_for(c, newrow[r]) }))
        end
      end
      remap[#remap + 1] = tag_of(r) .. "=" .. tag_of(newrow[r])
    end
  end
  syncing = false

  if #remap > 0 then hl.exec_cmd("hypr-ws-desc remap " .. table.concat(remap, " ")) end

  -- bring the focused monitor (and its lock-step peers) back onto the tag it was on, now compacted
  if origin then
    hl.dispatch(hl.dsp.focus({ monitor = origin }))
    set_all_to_row(frow and (newrow[frow] or math.min(frow, top)) or 1)
  end
  -- A compaction can leave a column split across monitors -- its renames/refocus never move a workspace
  -- between monitors, so a column whose home had already drifted stays split -- and nothing else heals on a
  -- window close, so the split would linger until the next login. Consolidate any split column now, so
  -- closing tags never strands one on the wrong monitor.
  heal_split_columns()
  hl.exec_cmd("pkill -RTMIN+11 waybar")
  reconciling = false
end

-- Step every locked monitor up/down one row together (creates grid workspaces on demand). I.e.
-- delta=1 moves toward later tags (home->a->b), delta=-1 back toward the home workspace.
local function go_row(delta)
  local _, row = current_cell()
  if not row then return end
  local target = math.max(1, math.min(MAX_ROWS, row + delta))
  if target ~= row then set_all_to_row(target) end
end

-- Move the active window to the tag above/below AND take every monitor there with it, so the whole grid
-- follows the window in lock-step -- exactly like Super+Ctrl+J/K does without shift. We move the window
-- silently (follow=false) so focus stays put, then set_all_to_row lock-steps every monitor -- including the
-- focused one, which lands on the workspace the window moved to (its focus fires the workspace.active
-- handler that refreshes current_row + the waybar description). reconcile_tags then squeezes out any tag row
-- the move just emptied. I.e. delta=1 carries the window (and the grid) home -> a -> b.
local function move_row(delta)
  local col, row = current_cell()
  if not col then return end
  local target = math.max(1, math.min(MAX_ROWS, row + delta))
  if target == row then return end
  hl.dispatch(hl.dsp.window.move({ workspace = selector_for(col, target), follow = false }))
  set_all_to_row(target)
  reconcile_tags()
end

-- Jump every locked monitor straight to a row together. I.e. row=1 is each column's home workspace,
-- row=2 its "a" grid workspace.
local function jump_row(row)
  set_all_to_row(math.max(1, math.min(MAX_ROWS, row)))
end

-- Switch the focused monitor to home column `col`, landing on the current tag when that column has
-- grid workspaces (else its home workspace). I.e. on tag "b", go_column("2") -> "2b" if 2* exists,
-- otherwise "2". If that workspace does not exist yet, first jump to the monitor already hosting this
-- column so the new tag is created there (keeping the whole column on one monitor) rather than here.
local function go_column(col)
  local row = (grid_columns()[col] and current_row) or 1
  if not workspace_exists(ws_name_for(col, row)) then
    local mon = column_monitor(col)
    if mon then hl.dispatch(hl.dsp.focus({ monitor = mon })) end
  end
  hl.dispatch(hl.dsp.focus({ workspace = selector_for(col, row) }))
end

-- Move the focused column -- home workspace plus every grid tag -- to the monitor left/right of it, so a
-- column always travels as a unit and never splits across monitors. dir "l"/"r"; no-op at the edge.
-- I.e. on 3a, "r" carries 3,3a(,3b,3c) one monitor right and leaves you focused on 3a over there.
local function move_column_to_monitor(dir)
  local col = current_cell()
  if not col then return end
  local target = adjacent_monitor(dir)
  if not target then return end
  -- Move the inactive tags first, then the focused workspace LAST. Moving the focused workspace carries
  -- focus with it and surfaces it on the destination, so no manual refocus is needed -- an extra focus
  -- dispatch only bounces us back off the destination, leaving the column hidden behind its old window.
  local active_name = (hl.get_active_workspace() or {}).name
  relocating = true -- this move is deliberate; keep heal_split_columns from fighting the transient split
  for _, ws in ipairs(hl.get_workspaces()) do
    local c, r = cell_of(ws.name)
    if c == col and ws.name ~= active_name then
      hl.dispatch(hl.dsp.workspace.move({ workspace = selector_for(c, r), monitor = target }))
    end
  end
  if active_name then
    hl.dispatch(hl.dsp.workspace.move({ workspace = selector_for(cell_of(active_name)), monitor = target }))
  end
  relocating = false
end

-- All existing home + grid workspaces in reading order. I.e. -> {"1","2","2a","2b","3"} by (column, row).
local function grid_workspaces()
  local list = {}
  for _, ws in ipairs(hl.get_workspaces()) do
    local col, tag = (ws.name or ""):match("^(%d+)(%a*)$")
    if col then
      list[#list + 1] = { name = ws.name, col = tonumber(col),
        row = (tag ~= "" and tag:byte(1) - string.byte("a") + 2) or 1 }
    end
  end
  table.sort(list, function(a, b)
    if a.col ~= b.col then return a.col < b.col end
    return a.row < b.row
  end)
  return list
end

-- Walk left/right through every existing home + grid workspace, wrapping (focused monitor only). I.e. delta=1 steps right.
local function walk(delta)
  local list = grid_workspaces()
  if #list == 0 then return end
  local cur = hl.get_active_workspace()
  local idx = 1
  for i, ws in ipairs(list) do
    if cur and ws.name == cur.name then
      idx = i
      break
    end
  end
  local target = list[(idx - 1 + delta) % #list + 1]
  hl.dispatch(hl.dsp.focus({ workspace = selector_for(tostring(target.col), target.row) }))
end

hl.bind("SUPER + CTRL + K", function() go_row(-1) end, { description = "Grid row up (all monitors)", repeating = true })
hl.bind("SUPER + CTRL + J", function() go_row(1) end, { description = "Grid row down (all monitors)", repeating = true })
hl.bind("SUPER + CTRL + SHIFT + K", function() move_row(-1) end, { description = "Move window up a task (all monitors follow)" })
hl.bind("SUPER + CTRL + SHIFT + J", function() move_row(1) end, { description = "Move window down a task (all monitors follow)" })
hl.unbind("SUPER + CTRL + H") -- was "Hardware menu" (omarchy default); use grid-aware walk instead
hl.unbind("SUPER + CTRL + L") -- was "Lock system" (omarchy default); walk right takes it
hl.bind("SUPER + CTRL + L", function() walk(1) end, { description = "Walk to next workspace (grid order)", repeating = true })
hl.bind("SUPER + CTRL + H", function() walk(-1) end, { description = "Walk to previous workspace (grid order)", repeating = true })
-- Whole-column moves across monitors (defined here, not bindings.lua, so they can carry every grid tag).
o.bind("SUPER + SHIFT + Y", "Move column to monitor on left", function() move_column_to_monitor("l") end)
o.bind("SUPER + SHIFT + O", "Move column to monitor on right", function() move_column_to_monitor("r") end)
for row = 1, MAX_ROWS do
  hl.bind("SUPER + CTRL + code:" .. tostring(row + 9), function() jump_row(row) end,
    { description = "Jump to grid row " .. row .. " (all monitors)" })
end

-- Re-point the Omarchy Super+1..0 workspace switches (SUPER+code:10..19) at the current tag: if the
-- target home column has grid workspaces, Super+N goes to that column's current-tag grid workspace
-- (e.g. "2b"); otherwise it still goes to the bare home workspace. Unbind first: Omarchy bound these.
for n = 1, 10 do
  local col = tostring(n) -- n=10 -> column "10" (Super+0)
  local key = "SUPER + code:" .. tostring(n + 9)
  hl.unbind(key)
  o.bind(key, "Switch to workspace " .. col .. " (current tag)", function() go_column(col) end)
end

-- Present Super+0's workspace (Hyprland's numbered workspace 10) as "0". Its id stays 10 so the numeric
-- selector above still lands on it; only the display name changes. Waybar sorts by name, so "0" sits at the
-- FRONT of the bar (0,1,2,2a,...) instead of the raw "10" wedging lexicographically between "1" and "2".
hl.workspace_rule({ workspace = 10, default_name = "0" })

-- Waybar descriptions (see ~/.local/bin/hypr-ws-desc): a home workspace shows its own label
-- (1=ide, 2=terminal, ...); a grid workspace shows its tag's shared label (every *a alike, etc.).
o.bind("SUPER + D", "Set workspace description", os.getenv("HOME") .. "/.local/bin/hypr-ws-desc set")
-- Remember the current tag (for Super+N) and refresh the waybar description on any active-ws change.
-- Only grid workspaces update the tag; landing on a home workspace keeps the previously active tag.
hl.on("workspace.active", function(ws)
  local _, row = cell_of(ws and ws.name)
  if row and row >= 2 then current_row = row end
  hl.exec_cmd("pkill -RTMIN+11 waybar")
end)
-- When a grid workspace is removed (e.g. its last window closed), close the tag gap it left in its
-- column. The removed workspace is already gone from hl.get_workspaces() by the time this fires, so
-- we can renumber the survivors synchronously. Skipped mid-sync so lock-step isn't pulled off its row.
hl.on("window.open", function() if not syncing then reconcile_tags() end end)
hl.on("window.destroy", function() if not syncing then reconcile_tags() end end)
-- Re-consolidate columns shortly after anything that can split them: a workspace changing monitors (a
-- stray move, a numbered-workspace reassignment) or the output layout changing (sleep/resume, hotplug,
-- which is what drifts a home workspace away from its tags).
hl.on("workspace.move_to_monitor", schedule_heal)
hl.on("monitor.added", schedule_heal)
hl.on("monitor.removed", schedule_heal)
hl.on("monitor.layout_changed", schedule_heal)
-- On login/reboot, reset the runtime descriptions from the git-tracked defaults, and consolidate any
-- columns that came up split.
o.exec_on_start(os.getenv("HOME") .. "/.local/bin/hypr-ws-desc seed")
heal_split_columns()

-- OPTIONAL: give each home column a label and keep it always present. Uncomment to enable.
-- With waybar's format set to "{name}", the bar then reads "ide term web work ... slack".
-- local columns = { ["1"] = "ide", ["2"] = "term", ["3"] = "web", ["4"] = "work", ["8"] = "slack" }
-- for id, label in pairs(columns) do
--   hl.workspace_rule({ workspace = id, default_name = label, persistent = true })
-- end

