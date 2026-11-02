local H = require("harness")

H.case("forward and backward goto", function()
  local n = 0
  goto skip
  n = n + 100
  ::skip::
  n = n + 1
  ::loop::
  if n < 3 then
    n = n + 1
    goto loop
  end
  H.eq(n, 3)
end)

H.case("goto into nested blocks is rejected", function()
  local src = [[
    goto L
    do
      local x = 1
      ::L::
      return x
    end
  ]]
  local f, err = load(src)
  H.ok(f == nil, "should fail to compile")
  H.ok(err and err:find("goto"), "error mentions goto: " .. tostring(err))
end)

H.case("label visibility across do-end", function()
  local n = 0
  do
    goto out
    n = 9
  end
  ::out::
  H.eq(n, 0)
end)
