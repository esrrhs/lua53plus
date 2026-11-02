local H = require("harness")

H.case("operator precedence matrix", function()
  H.eq(1 + 2 << 1, 6)          -- + before <<
  H.eq(2 * 3 + 4, 10)
  H.eq(2 ^ 3 ^ 2, 512.0)       -- right assoc
  H.eq(not not true, true)
  H.eq(1 | 2 & 4, 1)           -- & before |
  H.eq(true or false and false, true) -- and before or
  H.eq(#{1,2} + 1, 3)
end)

H.case("unary mixes", function()
  H.eq(-2^2, -4.0)
  H.eq(#"ab" + 1, 3)
  H.eq(not nil and 1 or 0, 1)
end)
