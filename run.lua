#!/usr/bin/env lua
-- Test runner. Usage: lua run.lua [test-file ...]   (default: every tests/*.lua)
-- Run from the project root (~/other/hyprgrid).
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = require("harness")

local files = { ... }
if #files == 0 then
  local p = io.popen("ls tests/*.lua 2>/dev/null")
  for line in p:lines() do files[#files + 1] = line end
  p:close()
end

for _, f in ipairs(files) do
  io.write("\27[1m" .. f .. "\27[0m\n")
  dofile(f)
end

os.exit(H.report() and 0 or 1)
