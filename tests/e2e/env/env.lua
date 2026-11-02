local H = require("harness")

H.case("_ENV sandbox via load", function()
  local env = { x = 10, pairs = pairs, ipairs = ipairs }
  local f = assert(load("return x + 1", "sandbox", "t", env))
  H.eq(f(), 11)
  env.x = 20
  H.eq(f(), 21)
end)

H.case("function _ENV upvalue", function()
  local _ENV = { a = 1, print = print }
  local function f() return a end
  H.eq(f(), 1)
  -- mutate env table still visible
  _ENV.a = 5
  H.eq(f(), 5)
end)

H.case("chunk inherits _ENV", function()
  local env = setmetatable({ y = 3 }, { __index = _G })
  local f = assert(load("return y * 2", nil, "t", env))
  H.eq(f(), 6)
end)

H.case("debug setupvalue _ENV", function()
  local dbg = require("debug")
  local env = { z = 9 }
  local f = assert(load("return z", nil, "t", env))
  H.eq(f(), 9)
  local name, val = dbg.getupvalue(f, 1)
  H.eq(name, "_ENV")
  H.ok(val == env)
end)
