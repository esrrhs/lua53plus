local H = require("harness")

H.case("insert remove move", function()
  local t = {1, 3}
  table.insert(t, 2, 2)
  H.deepeq(t, {1,2,3})
  H.eq(table.remove(t, 2), 2)
  H.deepeq(t, {1,3})
  local a = {1,2,3,4}
  table.move(a, 2, 4, 1)
  H.eq(a[1], 2); H.eq(a[2], 3); H.eq(a[3], 4)
end)

H.case("concat sort pack unpack", function()
  H.eq(table.concat({"a","b","c"}, ","), "a,b,c")
  local t = {3,1,2}
  table.sort(t)
  H.deepeq(t, {1,2,3})
  table.sort(t, function(a,b) return a > b end)
  H.deepeq(t, {3,2,1})
  local p = table.pack(9, nil, 8)
  H.eq(p.n, 3)
  local x, y, z = table.unpack({5,6,7})
  H.eq(x,5); H.eq(y,6); H.eq(z,7)
end)
