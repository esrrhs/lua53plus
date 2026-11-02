local H = require("harness")

H.case("and/or short-circuit", function()
  local hits = 0
  local function mark(v) hits = hits + 1; return v end
  H.eq(false and mark(1), false)
  H.eq(hits, 0)
  H.eq(true and mark(2), 2)
  H.eq(hits, 1)
  H.eq(true or mark(3), true)
  H.eq(hits, 1)
  H.eq(nil or mark(4), 4)
  H.eq(hits, 2)
end)

H.case("and/or return values", function()
  H.eq(1 and 2, 2)
  H.eq(nil and 2, nil)
  H.eq(false or "x", "x")
  H.eq("a" or "b", "a")
end)
