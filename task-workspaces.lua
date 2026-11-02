-- Optional desktop adapter. Load after workspace-grid.lua with require("hypr.task-workspaces")().
-- The coordinator creates the state directory; only this adapter writes row assignments.
return function(options)
  options = options or {}
  local state = os.getenv("HYPRGRID_STATE_DIR") or
    ((os.getenv("XDG_STATE_HOME") or os.getenv("HOME") .. "/.local/state") .. "/hyprgrid")
  local path = options.path
  if path == nil then path = state .. "/rows.tsv" end
  local command = options.command or "hyprgrid-task"
  hyprgrid.columns = options.columns or { ["1"] = true, ["2"] = true, ["3"] = true }
  -- Keep letter shortcuts stable; new/restored tasks claim holes instead of shifting other rows.
  hyprgrid.stable_rows = true
  -- Omarchy's universal clipboard shortcuts select Ctrl+Shift+C/V using this tag.
  o.window("(org\\.hyprgrid\\.task[a-z0-9]+|hyprgrid-[a-z0-9]+)", { tag = "+terminal" })
  local hint

  -- A tiny data-only file avoids evaluating generated Lua in the compositor.
  if path then
    local file = io.open(path, "r")
    if file then
      local occupied = {}
      for line in file:lines() do
        local id, row = line:match("^([a-z0-9-]+)\t(%d+)$")
        row = tonumber(row)
        assert(id and row and row >= 2 and row <= 13 and not occupied[row], "Invalid task row file")
        occupied[row] = true
        hyprgrid.rows[id] = row
      end
      file:close()
    end
  end

  hyprgrid.on_rows_changed = function()
    if not path then return end
    local file = assert(io.open(path .. ".tmp", "w"))
    local ids = {}
    for id in pairs(hyprgrid.rows) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do file:write(id .. "\t" .. hyprgrid.rows[id] .. "\n") end
    assert(file:close())
    assert(os.rename(path .. ".tmp", path))
  end

  -- Capture the launch workspace before Zed can activate a different one.
  hyprgrid.zed_targets = {}
  function hyprgrid.prepare_zed(id, project)
    local workspace = hl.get_active_workspace()
    local target = workspace.name:match("^%d+$") and tostring(workspace.id)
      or "name:" .. workspace.name
    table.insert(hyprgrid.zed_targets, { id = id, project = project, target = target })
  end

  -- Route by task identity rather than focus: applications can map after focus changes.
  -- Defer window movement until the native window-open callback has returned.
  hl.on("window.open", function(window)
    local app_id = window.initial_class or window.class or ""
    -- GTK rejects undotted app IDs; retain the old form for terminals opened by earlier versions.
    local id = app_id:match("^org%.hyprgrid%.task([a-z0-9]+)$") or app_id:match("^hyprgrid%-([a-z0-9]+)$")
    local target, follow
    if app_id == "dev.zed.Zed" then
      -- Nested checkouts have a clean repo basename, so match the pending launch's project title.
      local title = window.initial_title or window.title or ""
      for index, launch in ipairs(hyprgrid.zed_targets) do
        if launch.project == title then
          id, target = launch.id, launch.target
          table.remove(hyprgrid.zed_targets, index)
          break
        end
      end
      if not target then return end
      follow = true
    end
    local address = window.address
    if not id or not hyprgrid.rows[id] then return end
    hl.timer(function()
      local row = hyprgrid.rows[id]
      if not row then return end
      for _, candidate in ipairs(hl.get_windows()) do
        if candidate.address == address and (candidate.initial_class or candidate.class) == app_id then
          target = target or "name:2" .. string.char(string.byte("a") + row - 2)
          hyprgrid.route_window(address, target, follow)
        end
      end
    end, { timeout = 1, type = "oneshot" })
  end)

  -- Capture identity on close: window.destroy can receive nil after its weak reference expires.
  -- Defer the empty-row check until close returns; the coordinator rechecks under its lifecycle lock.
  hl.on("window.close", function(window)
    local letter = window.workspace and window.workspace.name:match("^%d+([a-l])$")
    if not letter or not window.address then return end
    local row = letter:byte() - string.byte("a") + 2
    local id
    for task_id, reserved in pairs(hyprgrid.rows) do
      if row == reserved then id = task_id; break end
    end
    if not id then return end
    hl.timer(function()
      local row = hyprgrid.rows[id]
      if not row then return end
      local letter = string.char(string.byte("a") + row - 2)
      for _, workspace in ipairs(hl.get_workspaces()) do
        if workspace.name:match("^%d+" .. letter .. "$") and (workspace.windows or 0) > 0 then return end
      end
      hl.exec_cmd(command .. " archive-empty " .. id)
    end, { timeout = 1, type = "oneshot" })
  end)

  hl.on("workspace.active", function(workspace)
    local letter = workspace and workspace.name:match("^%d+([a-l])$")
    if not letter then return end
    local row = letter:byte() - string.byte("a") + 2
    for id, reserved in pairs(hyprgrid.rows) do
      if row == reserved then hl.exec_cmd(command .. " acknowledge " .. id); return end
    end
  end)

  -- Reset before launching a picker so its text input cannot hit task bindings.
  local function leave()
    hl.dispatch(hl.dsp.submap("reset"))
    if hint then hint:dismiss(); hint = nil end
  end

  local function action(name)
    -- Capture the row before opening a menu or moving focus to another monitor.
    local ws = hl.get_active_workspace()
    local letter = ws and ws.name:match("^%d+([a-l])$")
    local id
    for candidate, row in pairs(hyprgrid.rows) do
      if letter and row == letter:byte() - string.byte("a") + 2 then id = candidate end
    end
    leave()
    -- Managed rows display the task name directly; only unmanaged rows own a separate description.
    if name == "rename" and not id then
      hl.exec_cmd(os.getenv("HOME") .. "/.local/bin/hypr-ws-desc set")
      return
    end
    hl.exec_cmd(command .. " menu " .. name .. (id and (" --task " .. id) or ""))
  end

  hl.unbind("SUPER + D") -- replaces the grid's description-only prompt
  hl.bind("SUPER + D", function() action("rename") end,
    { description = "Rename task or workspace" })

  hl.unbind("SUPER + SHIFT + RETURN") -- replaces Chromium's reuse-or-launch profile chooser
  hl.bind("SUPER + SHIFT + RETURN", function() action("browser") end,
    { description = "New browser window (choose profile)" })

  hl.unbind("SUPER + T") -- replaces OpenWhispr tap-to-dictate
  hl.bind("SUPER + T", function()
    hl.dispatch(hl.dsp.submap("hyprgrid-tasks"))
    if hl.notification then
      if hint then hint:dismiss() end
      hint = hl.notification.create({ text = "TASKS  a–l jump · Enter picker · n new · s snooze · x archive · r restore · Space actions · Esc cancel", timeout = 60000 })
    end
  end, { description = "Tasks" })

  hl.define_submap("hyprgrid-tasks", function()
    for code = string.byte("a"), string.byte("l") do
      local letter = string.char(code)
      hl.bind(letter, function() leave(); hyprgrid.jump_letter(letter) end,
        { description = "Jump to task " .. letter })
    end
    for key, name in pairs({ Return = "switch", n = "new", s = "snooze", x = "archive", r = "restore", space = "actions" }) do
      hl.bind(key, function() action(name) end, { description = "Task " .. name })
    end
    hl.bind("0", function() leave(); hyprgrid.jump_letter("0") end)
    hl.bind("Escape", leave)
    hl.bind("catchall", leave)
  end)
  hyprgrid.tasks_enabled = true
end
