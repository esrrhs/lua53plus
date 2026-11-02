local H = require("harness")

H.case("if elseif else", function()
  local function classify(n)
    if n < 0 then return "neg"
    elseif n == 0 then return "zero"
    else return "pos" end
  end
  H.eq(classify(-1), "neg")
  H.eq(classify(0), "zero")
  H.eq(classify(2), "pos")
end)

H.case("while and repeat", function()
  local i, s = 0, 0
  while i < 5 do i = i + 1; s = s + i end
  H.eq(s, 15)
  local j = 0
  repeat j = j + 1 until j == 3
  H.eq(j, 3)
end)

H.case("break from loops", function()
  local n = 0
  for i = 1, 100 do
    n = i
    if i == 7 then break end
  end
  H.eq(n, 7)
  local m = 0
  while true do
    m = m + 1
    if m >= 4 then break end
  end
  H.eq(m, 4)
end)
