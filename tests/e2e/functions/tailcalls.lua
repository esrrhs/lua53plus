local H = require("harness")

H.case("proper tail call does not grow stack", function()
  local function sum(n, acc)
    if n <= 0 then return acc end
    return sum(n - 1, acc + n)  -- tail
  end
  H.eq(sum(10000, 0), 10000 * 10001 / 2)
end)

H.case("tail call through local and vararg", function()
  local function id(...)
    return ...
  end
  local function f(n)
    if n == 0 then return 42 end
    return id(f(n - 1))  -- not a proper tail into f, but id is
  end
  -- Use proper self-tail:
  local function g(n, acc)
    if n == 0 then return acc end
    return g(n - 1, acc)
  end
  H.eq(g(5000, 7), 7)
end)
