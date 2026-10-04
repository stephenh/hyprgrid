-- User override of Omarchy's per-monitor workspace module (added 2026-10-20).
-- bootstrap.lua searches ~/.config before /usr/share/omarchy and clears this
-- module on reload. Keep global workspace numbers for hypr.workspace-grid;
-- do not install the stock reload/hotplug handlers that renumber workspaces.
local M = { slots = 10 }

-- A global workspace number does not depend on which monitor is focused.
function M.workspace_id(monitor, slot)
  return slot
end

-- Preserve the optional monitor argument used by Omarchy's workspace widget.
function M.focus(slot, monitor_name)
  if not monitor_name then
    return hl.dsp.focus({ workspace = tostring(slot) })
  end

  local function focus()
    hl.dispatch(hl.dsp.focus({ monitor = monitor_name }))
    hl.dispatch(hl.dsp.focus({ workspace = tostring(slot) }))
  end

  o.bind_expressions[focus] = "o.workspaces.focus(" .. slot .. ", " .. string.format("%q", monitor_name) .. ")"
  return focus
end

-- Super+Shift+N and its silent variant must use the same global N as Super+N.
function M.move_window(slot, follow)
  return hl.dsp.window.move({ workspace = tostring(slot), follow = follow ~= false })
end

-- Moving a workspace to another monitor must not change its number.
function M.move_to_monitor(direction)
  return hl.dsp.workspace.move({ monitor = direction })
end

-- Moving a window between monitors keeps the destination's visible workspace.
function M.move_window_to_monitor(direction)
  return hl.dsp.window.move({ monitor = direction })
end

o.workspaces = M
return M
