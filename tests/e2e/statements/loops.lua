local H = require("harness")

H.case("numeric for inclusive and step", function()
  local t = {}
  for i = 1, 5 do t[#t+1] = i end
  H.deepeq(t, {1,2,3,4,5})
  local u = {}
  for i = 5, 1, -2 do u[#u+1] = i end
  H.deepeq(u, {5,3,1})
  local c = 0
  for i = 1, 0 do c = c + 1 end
  H.eq(c, 0)
end)

H.case("generic for with ipairs/pairs", function()
  local sum = 0
  for i, v in ipairs({10, 20, 30}) do
    sum = sum + i * v
  end
  H.eq(sum, 1*10 + 2*20 + 3*30)
  local keys = {}
  for k in pairs({a=1, b=2}) do keys[#keys+1] = k end
  table.sort(keys)
  H.deepeq(keys, {"a","b"})
end)

H.case("custom iterator", function()
  local function range(n)
    local i = 0
    return function()
      i = i + 1
      if i <= n then return i end
    end
  end
  local s = 0
  for v in range(4) do s = s + v end
  H.eq(s, 10)
end)
