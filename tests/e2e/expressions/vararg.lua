local H = require("harness")

H.case("select and pack", function()
  local function f(...)
    return select("#", ...), select(2, ...)
  end
  local n, a, b = f(10, 20, 30)
  H.eq(n, 3)
  H.eq(a, 20)
  H.eq(b, 30)
  local t = table.pack(1, nil, 3)
  H.eq(t.n, 3)
  H.eq(t[1], 1)
  H.eq(t[3], 3)
end)

H.case("vararg adjust and multiple results", function()
  local function multi() return 1, 2, 3 end
  local function take(a, b, c, d)
    return a, b, c, d
  end
  local a, b, c, d = take(multi())
  H.eq(a, 1); H.eq(b, 2); H.eq(c, 3); H.eq(d, nil)
  local x, y = multi(), 9
  H.eq(x, 1); H.eq(y, 9) -- multi truncated in middle
end)

H.case("table constructor with vararg", function()
  local function g() return 4, 5 end
  local t = {1, 2, g()}
  H.eq(t[1], 1); H.eq(t[2], 2); H.eq(t[3], 4); H.eq(t[4], 5)
  local u = {g(), n = 1}
  H.eq(u[1], 4); H.eq(u[2], nil); H.eq(u.n, 1)
end)
