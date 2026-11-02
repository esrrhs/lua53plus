local H = require("harness")

H.case("multiple assignment and swap", function()
  local a, b, c = 1, 2, 3
  H.eq(a, 1); H.eq(b, 2); H.eq(c, 3)
  a, b = b, a
  H.eq(a, 2); H.eq(b, 1)
  local x, y = 1
  H.eq(x, 1); H.eq(y, nil)
  local p, q = 1, 2, 3
  H.eq(p, 1); H.eq(q, 2)
end)

H.case("local scoping", function()
  local x = 1
  do
    local x = 2
    H.eq(x, 2)
  end
  H.eq(x, 1)
  local y
  H.eq(y, nil)
end)

H.case("table field assign", function()
  local t = {a = 1}
  t.b = 2
  t[3] = 3
  H.eq(t.a, 1); H.eq(t.b, 2); H.eq(t[3], 3)
end)
