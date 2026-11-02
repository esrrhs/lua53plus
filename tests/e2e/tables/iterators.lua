local H = require("harness")

H.case("next traversal", function()
  local t = {a = 1, b = 2}
  local seen = {}
  local k = nil
  while true do
    local v
    k, v = next(t, k)
    if k == nil then break end
    seen[k] = v
  end
  H.deepeq(seen, {a = 1, b = 2})
end)

H.case("ipairs stops at first nil", function()
  local t = {10, 20, nil, 40}
  local n = 0
  for i, v in ipairs(t) do
    n = n + 1
    H.eq(v, t[i])
  end
  H.eq(n, 2)
end)

H.case("pairs visits all keys", function()
  local t = {[1]=1, [3]=3, x=9}
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  H.eq(c, 3)
end)
