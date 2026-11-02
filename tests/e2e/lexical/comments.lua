local H = require("harness")

H.case("short and long comments", function()
  local a = 1 -- comment
  --[[ block
       comment ]]
  local b = 2
  --[=[ nested brackets ok ]=]
  H.eq(a + b, 3)
end)

H.case("long comment nest levels", function()
  --[==[
    --[=[ inner ]=]
  ]==]
  H.eq(true, true)
end)
