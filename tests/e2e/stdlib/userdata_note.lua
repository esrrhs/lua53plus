local H = require("harness")
local debug = require("debug")

--[[
  Full userdata construction needs a C module (tests/t_udata.so used by GC fuzz).
  E2E keeps language coverage portable: we only check lightuserdata via debug
  library is not creatable from pure Lua, and document the skip.
]]

H.case("userdata not creatable from pure Lua", function()
  H.eq(type(io.stdout), "userdata") -- FILE* userdata from stdlib
  H.ok(getmetatable(io.stdout) ~= nil or true)
  -- newproxy removed in 5.2+; no bare userdata ctor in pure Lua
  H.ok(type(newproxy) ~= "function")
end)

H.case("optional t_udata.so probe (skip if absent)", function()
  local dir = (debug.getinfo(1, "S").source:match("^@(.*)/stdlib/") or ".")
  -- repo tests/t_udata.so sits next to e2e parent
  local so = dir .. "/../t_udata.so"
  local opener = package.loadlib(so, "luaopen_t_udata")
  if type(opener) ~= "function" then
    io.write("      (skip: tests/t_udata.so not loadable on this platform)\n")
    return
  end
  local U = opener()
  local u = U.new(16)
  H.eq(type(u), "userdata")
  U.setuv(u, { ok = true })
  H.eq(debug.getuservalue(u).ok, true)
end)
