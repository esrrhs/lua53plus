--[[
  Shared helpers for lua53plus language/stdlib e2e tests (non-GC).
  Each case file calls H.case(name, fn); run_all.lua drives discovery.
]]

local H = {}

H._suite = "?"
H._cases = 0
H._asserts = 0
H._failures = {}

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function fmt(v)
  local t = type(v)
  if t == "string" then
    return string.format("%q", v)
  elseif t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = "[" .. fmt(k) .. "]=" .. fmt(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  else
    return tostring(v)
  end
end

function H.eq(got, expect, msg)
  H._asserts = H._asserts + 1
  if got ~= expect then
    error((msg or "eq") .. ": expected " .. fmt(expect) .. ", got " .. fmt(got), 2)
  end
end

function H.neq(got, not_expect, msg)
  H._asserts = H._asserts + 1
  if got == not_expect then
    error((msg or "neq") .. ": values should differ, both are " .. fmt(got), 2)
  end
end

function H.deepeq(got, expect, msg)
  H._asserts = H._asserts + 1
  if not deep_eq(got, expect) then
    error((msg or "deepeq") .. ": expected " .. fmt(expect) .. ", got " .. fmt(got), 2)
  end
end

function H.ok(cond, msg)
  H._asserts = H._asserts + 1
  if not cond then
    error(msg or "assertion failed", 2)
  end
end

function H.fail(msg)
  H._asserts = H._asserts + 1
  error(msg or "forced failure", 2)
end

function H.raises(fn, pattern, msg)
  H._asserts = H._asserts + 1
  local ok, err = pcall(fn)
  if ok then
    error((msg or "raises") .. ": expected error, got success", 2)
  end
  local s = tostring(err)
  if pattern and not string.find(s, pattern, 1, false) then
    error((msg or "raises") .. ": error " .. fmt(s) .. " did not match /" .. pattern .. "/", 2)
  end
  return err
end

function H.near(got, expect, eps, msg)
  H._asserts = H._asserts + 1
  eps = eps or 1e-9
  if type(got) ~= "number" or math.abs(got - expect) > eps then
    error((msg or "near") .. ": expected ~" .. tostring(expect) .. " (±" .. tostring(eps) .. "), got " .. tostring(got), 2)
  end
end

function H.case(name, fn)
  H._cases = H._cases + 1
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    H._failures[#H._failures + 1] = {
      suite = H._suite,
      case = name,
      err = err,
    }
    io.write("    FAIL  " .. name .. "\n")
    io.write("          " .. tostring(err):gsub("\n", "\n          ") .. "\n")
  else
    io.write("    ok    " .. name .. "\n")
  end
end

function H.suite(name)
  H._suite = name
  io.write("  [" .. name .. "]\n")
end

function H.summary_ok()
  return #H._failures == 0
end

function H.report()
  return {
    cases = H._cases,
    asserts = H._asserts,
    failures = H._failures,
  }
end

return H
