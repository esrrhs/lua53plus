local H = require("harness")

H.case("multiple returns assignment", function()
  local function f() return 1, 2, 3 end
  local a, b, c, d = f()
  H.eq(a, 1); H.eq(b, 2); H.eq(c, 3); H.eq(d, nil)
end)

H.case("return in expression list contexts", function()
  local function f() return 10, 20 end
  local t = {f()}
  H.eq(#t, 2)
  H.eq(t[1], 10); H.eq(t[2], 20)
  local function g(a, b, c) return a + b + (c or 0) end
  H.eq(g(f()), 30)          -- f() last => both results
  H.eq(g(f(), 1), 11)       -- f() not last => truncated to 10, then +1
  H.eq(g(1, f()), 31)       -- f() last => 1+10+20
end)

H.case("pcall preserves multiple returns", function()
  local ok, a, b = pcall(function() return 5, 6 end)
  H.ok(ok)
  H.eq(a, 5); H.eq(b, 6)
end)
