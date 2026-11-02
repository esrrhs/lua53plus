--[[
  End-to-end language / stdlib suite runner for lua53plus (excludes GC fuzz).
  Usage (from repo root):  ./src/lua tests/e2e/run_all.lua
]]

local debug = require("debug")

local src = debug.getinfo(1, "S").source
local e2e_dir = (src:match("^@(.*)/[^/]+$") or ".")
local repo_root = e2e_dir:match("^(.*)/tests/e2e$") or "."

package.path = e2e_dir .. "/?.lua;" .. e2e_dir .. "/?/init.lua;" .. package.path

local H = require("harness")

local function is_test_file(path)
  local base = path:match("([^/]+)$") or path
  if base == "harness.lua" or base == "run_all.lua" then return false end
  if base:sub(1, 1) == "_" then return false end
  return base:sub(-4) == ".lua"
end

local function list_lua_files(dir, acc)
  acc = acc or {}
  local p = io.popen('find "' .. dir .. '" -type f -name "*.lua" | sort')
  if not p then error("cannot list " .. dir) end
  for line in p:lines() do
    if is_test_file(line) and not line:find("/fixtures/", 1, true) then
      acc[#acc + 1] = line
    end
  end
  p:close()
  return acc
end

local files = list_lua_files(e2e_dir)
table.sort(files)

io.write("=== lua53plus e2e (language / stdlib, non-GC) ===\n")
io.write("root=" .. repo_root .. "  suites=" .. #files .. "\n")

local t0 = os.clock()
for _, path in ipairs(files) do
  local rel = path:sub(#e2e_dir + 2)
  H.suite(rel)
  local chunk, loaderr = loadfile(path)
  if not chunk then
    H._cases = H._cases + 1
    H._failures[#H._failures + 1] = { suite = rel, case = "<load>", err = loaderr }
    io.write("    FAIL  <load>\n          " .. tostring(loaderr) .. "\n")
  else
    local ok, err = xpcall(chunk, debug.traceback)
    if not ok then
      H._cases = H._cases + 1
      H._failures[#H._failures + 1] = { suite = rel, case = "<top>", err = err }
      io.write("    FAIL  <top>\n          " .. tostring(err):gsub("\n", "\n          ") .. "\n")
    end
  end
end
local elapsed = os.clock() - t0

local r = H.report()
io.write(string.format(
  "\n=== summary: %d cases, %d asserts, %d failures, %.2fs ===\n",
  r.cases, r.asserts, #r.failures, elapsed
))

if #r.failures > 0 then
  io.write("FAILURES:\n")
  for _, f in ipairs(r.failures) do
    io.write(string.format("  - %s :: %s\n", f.suite, f.case))
  end
  os.exit(1)
end

io.write("ALL E2E PASSED\n")
os.exit(0)
