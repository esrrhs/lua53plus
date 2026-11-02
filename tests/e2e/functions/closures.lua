local H = require("harness")

H.case("upvalues mutable", function()
  local function counter(start)
    local n = start
    return function()
      n = n + 1
      return n
    end
  end
  local c1 = counter(0)
  local c2 = counter(10)
  H.eq(c1(), 1)
  H.eq(c1(), 2)
  H.eq(c2(), 11)
  H.eq(c1(), 3)
end)

H.case("shared upvalue across closures", function()
  local x = 0
  local function inc() x = x + 1 end
  local function get() return x end
  inc(); inc()
  H.eq(get(), 2)
end)

H.case("nested closures", function()
  local function outer(a)
    return function(b)
      return function(c)
        return a + b + c
      end
    end
  end
  H.eq(outer(1)(2)(3), 6)
end)
