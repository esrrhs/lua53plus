local H = require("harness")

H.case("list and record constructors", function()
  local t = {1, 2, 3, a = 4, ["b"] = 5}
  H.eq(t[1], 1); H.eq(t[3], 3); H.eq(t.a, 4); H.eq(t.b, 5)
  local u = {[1] = "x", [true] = "y"}
  H.eq(u[1], "x"); H.eq(u[true], "y")
end)

H.case("nested constructors", function()
  local t = { {1}, {2, 3} }
  H.eq(t[1][1], 1)
  H.eq(t[2][2], 3)
end)

H.case("rawget/rawset bypass metatable", function()
  local t = {}
  setmetatable(t, {
    __index = function() return "miss" end,
    __newindex = function() error("no") end,
  })
  H.eq(t.x, "miss")
  rawset(t, "x", 9)
  H.eq(rawget(t, "x"), 9)
  H.eq(t.x, 9)
end)
