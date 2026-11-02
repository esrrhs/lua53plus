local H = require("harness")

H.case("__index / __newindex", function()
  local store = {}
  local t = setmetatable({}, {
    __index = store,
    __newindex = store,
  })
  t.a = 1
  H.eq(store.a, 1)
  H.eq(t.a, 1)
  H.eq(rawget(t, "a"), nil)
end)

H.case("__index as function and table", function()
  local t = setmetatable({}, { __index = { x = 7 } })
  H.eq(t.x, 7)
  local u = setmetatable({}, {
    __index = function(_, k) return k .. "!" end
  })
  H.eq(u.hi, "hi!")
end)

H.case("__call __len __tostring __name", function()
  local t = setmetatable({1,2}, {
    __call = function(self, x) return self[1] + x end,
    __len = function() return 99 end,
    __tostring = function() return "OBJ" end,
    __name = "MyObj",
  })
  H.eq(t(5), 6)
  H.eq(#t, 99)
  H.eq(tostring(t), "OBJ")
end)

H.case("arithmetic metamethods", function()
  local function box(n)
    return setmetatable({n = n}, {
      __add = function(a, b) return box(a.n + b.n) end,
      __sub = function(a, b) return box(a.n - b.n) end,
      __mul = function(a, b) return box(a.n * b.n) end,
      __div = function(a, b) return box(a.n / b.n) end,
      __mod = function(a, b) return box(a.n % b.n) end,
      __pow = function(a, b) return box(a.n ^ b.n) end,
      __unm = function(a) return box(-a.n) end,
      __idiv = function(a, b) return box(a.n // b.n) end,
      __band = function(a, b) return box(a.n & b.n) end,
      __bor = function(a, b) return box(a.n | b.n) end,
      __bxor = function(a, b) return box(a.n ~ b.n) end,
      __bnot = function(a) return box(~a.n) end,
      __shl = function(a, b) return box(a.n << b.n) end,
      __shr = function(a, b) return box(a.n >> b.n) end,
      __concat = function(a, b) return box(tonumber(tostring(a.n) .. tostring(b.n))) end,
    })
  end
  H.eq((box(2) + box(3)).n, 5)
  H.eq((box(5) - box(2)).n, 3)
  H.eq((box(3) * box(4)).n, 12)
  H.eq((box(9) / box(3)).n, 3.0)
  H.eq((box(10) % box(4)).n, 2)
  H.eq((box(2) ^ box(3)).n, 8.0)
  H.eq((-box(3)).n, -3)
  H.eq((box(7) // box(2)).n, 3)
  H.eq((box(0xF) & box(0x3)).n, 3)
  H.eq((box(1) | box(2)).n, 3)
  H.eq((box(0xF) ~ box(0xA)).n, 5)
  H.eq((~box(0)).n, -1)
  H.eq((box(1) << box(3)).n, 8)
  H.eq((box(8) >> box(1)).n, 4)
  H.eq((box(1) .. box(2)).n, 12)
end)

H.case("relational metamethods __eq __lt __le", function()
  local function pt(x, y)
    return setmetatable({x = x, y = y}, {
      __eq = function(a, b) return a.x == b.x and a.y == b.y end,
      __lt = function(a, b) return a.x < b.x or (a.x == b.x and a.y < b.y) end,
      __le = function(a, b) return a < b or a == b end,
    })
  end
  H.ok(pt(1,2) == pt(1,2))
  H.ok(pt(1,2) ~= pt(1,3))
  H.ok(pt(1,2) < pt(2,0))
  H.ok(pt(1,2) <= pt(1,2))
end)

H.case("__pairs custom", function()
  local t = setmetatable({}, {
    __pairs = function()
      local data = {a = 1, b = 2}
      return next, data, nil
    end
  })
  local seen = {}
  for k, v in pairs(t) do seen[k] = v end
  H.deepeq(seen, {a = 1, b = 2})
end)
