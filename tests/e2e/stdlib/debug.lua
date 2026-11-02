local H = require("harness")
local debug = require("debug")

H.case("getinfo traceback", function()
  local function f()
    return debug.getinfo(1, "nSl")
  end
  local info = f()
  H.eq(info.what, "Lua")
  H.ok(info.currentline > 0)
  H.ok(type(debug.traceback()) == "string")
end)

H.case("getlocal setlocal", function()
  local function f(a)
    local b = a + 1
    local name, val = debug.getlocal(1, 1)
    H.eq(name, "a")
    H.eq(val, 10)
    debug.setlocal(1, 2, 99)
    return b
  end
  H.eq(f(10), 99)
end)

H.case("upvalue helpers", function()
  local x = 1
  local function f() return x end
  H.eq(debug.getupvalue(f, 1), "x")
  local name, val = debug.getupvalue(f, 1)
  H.eq(val, 1)
  debug.setupvalue(f, 1, 5)
  H.eq(f(), 5)
end)

H.case("getmetatable via debug and getuservalue safe", function()
  local t = {}
  local mt = {}
  setmetatable(t, mt)
  H.ok(debug.getmetatable(t) == mt)
  H.eq(debug.getuservalue({}), nil)
end)

H.case("hook count", function()
  local hits = 0
  debug.sethook(function() hits = hits + 1 end, "", 10)
  for i = 1, 100 do end
  debug.sethook()
  H.ok(hits > 0)
end)
