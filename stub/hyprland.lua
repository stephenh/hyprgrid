-- StubHyprland: a fake `hl` / `o` API backed by an in-memory model that behaves the way real Hyprland
-- (0.55, Aquamarine) was observed to behave while debugging the grid. It exists so workspace-grid.lua can
-- be driven through user scenarios and asserted on, with zero risk to a live session.
--
-- Modeled behaviors (each learned the hard way on the real thing):
--   * A monitor always shows exactly one workspace (its "active"); the focused monitor's active workspace
--     is the global active workspace.
--   * Empty, non-persistent workspaces are disposed (garbage-collected) the moment they stop being visible
--     (i.e. are not the active workspace of any monitor). Disposal fires `workspace.removed`.
--   * Numbered home workspaces ("1".."10") get positive ids; named grid tags ("2a") get negative ids --
--     which is why a negative number is NOT a usable id selector (it reads as a relative offset).
--   * Focusing a workspace that does not exist CREATES it (empty) on the focused monitor.
--   * Focusing a workspace that lives on another monitor moves focus to that monitor.
--   * Renaming a workspace onto a name that already exists produces a DUPLICATE (two same-named ws).
--   * Renaming drops the persistent rule (rules are keyed by name), so renaming an EMPTY workspace makes
--     it non-persistent-and-empty -> it is disposed. A windowed workspace survives a rename.
--   * `workspace_rule{persistent=true}` creates the workspace if missing; `{persistent=false}` disposes it
--     if it is empty and not visible.
--   * `hl.timer` is deferred; the harness fires timers explicitly (models the debounce delay).
--
-- Known NON-fidelity (documented, acceptable for logic testing): everything here is synchronous and
-- deterministic. Real Hyprland has async focus/event races we cannot reproduce; the point of this stub is
-- to test the grid's *logic* (packing, renumber, persistence, which column/row/monitor), not races.

local Stub = {}

-- ------------------------------------------------------------------ state
local S -- the whole compositor model; (re)created by Stub.reset

-- Reset to a fresh compositor with the given monitors and install the hl/o globals.
-- monitors: array of { name=, x= } (y defaults 0). First one is focused. Each starts on home workspace "1"
-- unless `home` given. I.e. Stub.reset({ {name="DP-1", x=0}, {name="DP-2", x=2560} }).
function Stub.reset(monitors)
  S = {
    monitors = {},   -- array of { name, x, y, focused, active } (active = workspace name shown)
    workspaces = {}, -- array of { name, id, monitor, windows, persistent }
    windows = {},    -- array of { addr, ws }
    binds = {},      -- normalized-keys -> callback
    handlers = {},   -- event name -> array of callbacks
    desc = {},       -- description store, keyed by tag ("a") or home name ("2") -- like hypr-ws-desc's json
    timers = {},     -- pending { cb } from hl.timer
    next_named_id = -1000,
    next_addr = 0,
    log = {},        -- event log for debugging
  }
  for i, m in ipairs(monitors or { { name = "DP-1", x = 0 } }) do
    local home = m.home or tostring(i) -- each monitor starts on a distinct home workspace (1, 2, 3, ...)
    S.monitors[i] = { name = m.name, x = m.x or 0, y = m.y or 0, focused = (i == 1), active = home }
    if not Stub._find(home) then Stub._create(home, m.name) end
  end
  _G.hl = Stub.hl
  _G.o = Stub.o
end

-- Load and run a grid-style script against the current stub (fresh each call).
function Stub.load(path)
  local chunk, err = loadfile(path)
  if not chunk then error("failed to load " .. path .. ": " .. tostring(err)) end
  chunk()
end

-- ------------------------------------------------------------------ model helpers
local function is_named(name) return name:match("^%d+%a+$") ~= nil end -- grid tag like "2a"
local function is_numbered(name) return name:match("^%d+$") ~= nil end -- home like "2"

function Stub._find(name)
  for _, w in ipairs(S.workspaces) do if w.name == name then return w end end
end

-- Every workspace with this name (there can be >1 after a rename collision -- modeled on purpose).
local function find_all(name)
  local out = {}
  for _, w in ipairs(S.workspaces) do if w.name == name then out[#out + 1] = w end end
  return out
end

function Stub._create(name, monitor, persistent)
  local id
  if is_numbered(name) then id = tonumber(name) else id = S.next_named_id; S.next_named_id = S.next_named_id - 1 end
  local w = { name = name, id = id, monitor = monitor, windows = 0, persistent = persistent or false }
  S.workspaces[#S.workspaces + 1] = w
  return w
end

local function count_windows(name)
  local n = 0
  for _, win in ipairs(S.windows) do if win.ws == name then n = n + 1 end end
  return n
end

local function is_visible(name)
  for _, m in ipairs(S.monitors) do if m.active == name then return true end end
  return false
end

local function focused_monitor() for _, m in ipairs(S.monitors) do if m.focused then return m end end end

local function fire(event, arg)
  S.log[#S.log + 1] = event
  for _, cb in ipairs(S.handlers[event] or {}) do cb(arg) end
end

-- Dispose a workspace object (remove it) and fire workspace.removed.
local function dispose(w)
  for i, x in ipairs(S.workspaces) do
    if x == w then table.remove(S.workspaces, i); break end
  end
  fire("workspace.removed", { name = w.name, id = w.id })
end

-- Garbage-collect: any workspace that is empty, not persistent, and not visible on a monitor is disposed.
-- This is Hyprland auto-disposing empty workspaces the instant they stop being shown.
local function gc()
  local again = true
  while again do
    again = false
    for _, w in ipairs(S.workspaces) do
      w.windows = count_windows(w.name)
      if w.windows == 0 and not w.persistent and not is_visible(w.name) then
        dispose(w); again = true; break
      end
    end
  end
end

-- Keep window counts on workspace objects in sync (they are what get_workspaces reports).
local function refresh_counts()
  for _, w in ipairs(S.workspaces) do w.windows = count_windows(w.name) end
end

-- Interpret the side-effecting shell-outs the grid makes. Only "hypr-ws-desc remap OLD=NEW ..." affects the
-- model: it shifts per-tag descriptions when tags renumber (so tag a inherits b's label when b->a). Grid-tag
-- keys not named in the remap are dropped (compacted away); home (numeric) keys are preserved. Everything
-- else (pkill waybar, hypr-ws-desc seed/set) is a no-op here.
local function stub_exec(cmd)
  S.log[#S.log + 1] = "exec:" .. tostring(cmd)
  local args = tostring(cmd):match("^hypr%-ws%-desc%s+remap%s+(.+)$")
  if not args then return end
  local newdesc = {}
  for k, v in pairs(S.desc) do if k:match("^%d+$") then newdesc[k] = v end end -- keep home labels
  for old, new in args:gmatch("(%w+)=(%w+)") do
    if S.desc[old] ~= nil then newdesc[new] = S.desc[old] end -- read from the old snapshot
  end
  S.desc = newdesc
end

-- Focus a monitor: make it the focused one, fire workspace.active if the global active ws changed.
local function focus_monitor(name)
  local prev = focused_monitor()
  local prev_active = prev and prev.active
  for _, m in ipairs(S.monitors) do m.focused = (m.name == name) end
  local now = focused_monitor()
  if now and now.active ~= prev_active then fire("workspace.active", { name = now.active }) end
end

-- Show workspace `name` on the focused monitor, moving focus to its monitor if it lives elsewhere, and
-- creating it (empty, on the focused monitor) if it does not exist. Then GC whatever we uncovered.
local function focus_workspace(name)
  local w = Stub._find(name)
  local fm = focused_monitor()
  if not w then
    w = Stub._create(name, fm.name)
  end
  -- move focus to the workspace's monitor and surface it there
  focus_monitor(w.monitor)
  local m = Stub._find(w.monitor) and nil -- (monitor lookup below)
  for _, mm in ipairs(S.monitors) do if mm.name == w.monitor then mm.active = name end end
  fire("workspace.active", { name = name })
  gc()
end

-- ------------------------------------------------------------------ dispatchers
-- hl.dsp.* return opaque descriptors; hl.dispatch interprets them against the model.
local function apply(desc)
  local op = desc.op
  if op == "exec" then
    stub_exec(desc.cmd)
  elseif op == "focus" then
    if desc.monitor then
      focus_monitor(desc.monitor)
    elseif desc.workspace then
      focus_workspace(desc.workspace)
    end
  elseif op == "ws_move" then -- moveworkspacetomonitor
    local w = Stub._find(desc.workspace)
    if w then
      local was_global_active = (focused_monitor() and focused_monitor().active == w.name)
      -- if the monitor it left now shows nothing meaningful, give it another/ fresh workspace
      local old = w.monitor
      w.monitor = desc.monitor
      -- surface the moved workspace on its new monitor
      for _, mm in ipairs(S.monitors) do if mm.name == desc.monitor then mm.active = w.name end end
      -- the old monitor needs an active workspace that still lives on it
      for _, mm in ipairs(S.monitors) do
        if mm.name == old and mm.active == w.name then
          local repl
          for _, x in ipairs(S.workspaces) do if x.monitor == old and x.name ~= w.name then repl = x.name; break end end
          if not repl then repl = old:match("%d") and old or "1"; if not Stub._find(repl) then Stub._create(repl, old) end end
          mm.active = repl
        end
      end
      if was_global_active then focus_monitor(desc.monitor) end
      fire("workspace.move_to_monitor", { name = w.name, monitor = desc.monitor })
      gc()
    end
  elseif op == "ws_rename" then
    local w = Stub._find(desc.workspace)
    if w then
      local old = w.name
      w.name = desc.newname
      w.id = is_numbered(desc.newname) and tonumber(desc.newname) or w.id
      w.persistent = false -- rules are name-keyed; the old name's persistent rule no longer applies
      for _, win in ipairs(S.windows) do if win.ws == old then win.ws = desc.newname end end -- windows follow
      for _, mm in ipairs(S.monitors) do if mm.active == old then mm.active = desc.newname end end -- visibility follows
      refresh_counts()
      gc() -- an empty just-renamed (now non-persistent) workspace disposes here
    end
  elseif op == "win_move" then -- movetoworkspace(silent)
    local win = desc.window and (function() for _, x in ipairs(S.windows) do if x.addr == desc.window then return x end end end)()
      or (function() -- active window on focused monitor's active workspace
        local fm = focused_monitor()
        for _, x in ipairs(S.windows) do if x.ws == fm.active then return x end end
      end)()
    if win then
      if not Stub._find(desc.workspace) then Stub._create(desc.workspace, win_monitor(win)) end
      win.ws = desc.workspace
      if desc.follow ~= false then focus_workspace(desc.workspace) end
      refresh_counts(); gc()
    end
  end
end

-- monitor a window currently lives on (via its workspace)
function win_monitor(win)
  local w = Stub._find(win.ws)
  return w and w.monitor or focused_monitor().name
end

-- ------------------------------------------------------------------ selector normalization
-- Grid passes workspace selectors as "name:2a" (grid tag) or "2" (home) or a raw name. Normalize to a name.
local function sel_name(sel)
  if type(sel) == "string" then return (sel:gsub("^name:", "")) end
  return tostring(sel)
end

-- ------------------------------------------------------------------ the hl API
local hl = {}
Stub.hl = hl

hl.dsp = {
  focus = function(a)
    if a.monitor then return { op = "focus", monitor = a.monitor } end
    return { op = "focus", workspace = sel_name(a.workspace) }
  end,
  exec_cmd = function(cmd) return { op = "exec", cmd = cmd } end,
  workspace = {
    move = function(a) return { op = "ws_move", workspace = sel_name(a.workspace), monitor = a.monitor } end,
    rename = function(a) return { op = "ws_rename", workspace = sel_name(a.workspace), newname = sel_name(a.name) } end,
  },
  window = {
    move = function(a) return { op = "win_move", workspace = sel_name(a.workspace), window = a.window, follow = a.follow } end,
  },
}

function hl.dispatch(desc) if desc and desc.op then apply(desc) end end

function hl.get_workspaces()
  refresh_counts()
  local out = {}
  for _, w in ipairs(S.workspaces) do
    out[#out + 1] = {
      name = w.name, id = w.id, windows = w.windows, is_persistent = w.persistent,
      is_empty = (w.windows == 0), monitor = { name = w.monitor },
    }
  end
  return out
end

function hl.get_monitors()
  local out = {}
  for _, m in ipairs(S.monitors) do
    out[#out + 1] = {
      name = m.name, x = m.x, y = m.y, focused = m.focused, width = 1920, height = 1080,
      active_workspace = { name = m.active },
    }
  end
  return out
end

function hl.get_active_workspace()
  local m = focused_monitor()
  return m and { name = m.active } or nil
end

function hl.bind(keys, cb, _opts) S.binds[keys:gsub("%s+", "")] = cb end
function hl.unbind(keys) S.binds[keys:gsub("%s+", "")] = nil end
function hl.on(event, cb) S.handlers[event] = S.handlers[event] or {}; table.insert(S.handlers[event], cb) end
function hl.exec_cmd(cmd) stub_exec(cmd) end
function hl.timer(cb, _opts) S.timers[#S.timers + 1] = cb end
function hl.monitor(_spec) end -- test sets up monitors via Stub.reset; ignore config-time monitor rules

-- workspace_rule: persistence. persistent=true creates-if-missing (on `monitor` or focused); =false disposes
-- the workspace if it is empty and not visible.
function hl.workspace_rule(spec)
  local name = sel_name(spec.workspace)
  local w = Stub._find(name)
  if spec.persistent then
    if not w then w = Stub._create(name, spec.monitor or focused_monitor().name, true) else w.persistent = true end
  else
    if w then w.persistent = false; gc() end
  end
end

-- ------------------------------------------------------------------ the o (omarchy helper) API
local o = {}
Stub.o = o
function o.bind(keys, _desc, cb, _opts)
  if type(cb) == "function" then S.binds[keys:gsub("%s+", "")] = cb end
  -- string commands / launch-spec tables are no-ops in the stub
end
function o.exec_on_start(_cmd) end

-- ------------------------------------------------------------------ control surface for the harness
Stub.S = function() return S end
Stub.set_desc = function(key, text) S.desc[key] = text end
Stub.get_desc = function(key) return S.desc[key] end
-- Seed a window onto a workspace WITHOUT firing window.open (for building a state before triggering
-- reconcile). Creates the workspace on `monitor` if missing. Returns the window address.
Stub.seed_window = function(ws, monitor)
  if not Stub._find(ws) then Stub._create(ws, monitor or focused_monitor().name) end
  S.next_addr = S.next_addr + 1
  local addr = string.format("0x%x", S.next_addr)
  S.windows[#S.windows + 1] = { addr = addr, ws = ws }
  refresh_counts()
  return addr
end
Stub.press = function(keys)
  local cb = S.binds[keys:gsub("%s+", "")]
  if not cb then error("no keybind registered for '" .. keys .. "'") end
  cb()
end
Stub.run_timers = function()
  local t = S.timers; S.timers = {}
  for _, cb in ipairs(t) do cb() end
end
Stub.open_window = function(ws)
  ws = ws or (focused_monitor() and focused_monitor().active)
  if not Stub._find(ws) then Stub._create(ws, focused_monitor().name) end -- a window creates its workspace
  S.next_addr = S.next_addr + 1
  local addr = string.format("0x%x", S.next_addr)
  S.windows[#S.windows + 1] = { addr = addr, ws = ws }
  refresh_counts()
  fire("window.open", { address = addr, workspace = { name = ws } })
  return addr
end
Stub.close_window = function(addr)
  for i, x in ipairs(S.windows) do if x.addr == addr then table.remove(S.windows, i); break end end
  refresh_counts()
  fire("window.destroy", { address = addr })
  gc()
end
Stub.add_monitor = function(name, x)
  S.monitors[#S.monitors + 1] = { name = name, x = x, y = 0, focused = false, active = nil }
  -- a fresh monitor needs a workspace to show; Hyprland assigns one (use a free numbered home)
  local n = 1; while Stub._find(tostring(n)) do n = n + 1 end
  Stub._create(tostring(n), name)
  S.monitors[#S.monitors].active = tostring(n)
  fire("monitor.added", { name = name }); fire("monitor.layout_changed", {})
end
Stub.remove_monitor = function(name)
  local victim
  for i, m in ipairs(S.monitors) do if m.name == name then victim = m; table.remove(S.monitors, i); break end end
  if victim then
    -- Hyprland reshuffles the removed monitor's workspaces onto another monitor
    local dest = S.monitors[1]
    for _, w in ipairs(S.workspaces) do if w.monitor == name then w.monitor = dest.name end end
    fire("monitor.removed", { name = name }); fire("monitor.layout_changed", {})
  end
end

return Stub
