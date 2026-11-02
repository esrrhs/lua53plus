local H = require("harness")

H.case("sequence length", function()
  H.eq(#{}, 0)
  H.eq(#{1,2,3}, 3)
  local t = {1,2,3}; t[4] = 4
  H.eq(#t, 4)
end)

H.case("holes and border behavior", function()
  local t = {1, 2, nil, 4}
  -- length is a border; for {1,2,nil,4} border may be 2
  H.ok(#t == 2 or #t == 4)
  local u = table.pack(1, nil, 3)
  H.eq(u.n, 3)
end)

H.case("table.insert/remove affect length", function()
  local t = {1, 2}
  table.insert(t, 3)
  H.eq(#t, 3)
  H.eq(table.remove(t), 3)
  H.eq(#t, 2)
  table.insert(t, 1, 0)
  H.eq(t[1], 0); H.eq(t[2], 1); H.eq(t[3], 2)
end)
