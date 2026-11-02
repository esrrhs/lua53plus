local H = require("harness")

H.case("pcall success and failure", function()
  local ok, a, b = pcall(function() return 1, 2 end)
  H.ok(ok); H.eq(a, 1); H.eq(b, 2)
  ok, a = pcall(function() error("x") end)
  H.eq(ok, false)
  H.ok(tostring(a):find("x"))
end)

H.case("xpcall message handler", function()
  local ok, err = xpcall(function() error("z") end, function(e)
    return "handled:" .. tostring(e)
  end)
  H.eq(ok, false)
  H.ok(tostring(err):find("handled:"))
end)

H.case("error objects preserved", function()
  local obj = { code = 7 }
  local ok, err = pcall(function() error(obj) end)
  H.eq(ok, false)
  H.ok(err == obj)
  H.eq(err.code, 7)
end)

H.case("error level", function()
  local function inner() error("lvl", 2) end
  local function mid() inner() end
  local ok, err = pcall(mid)
  H.eq(ok, false)
  H.ok(type(err) == "string")
end)

H.case("assert", function()
  H.eq(assert(5), 5)
  local ok, err = pcall(function() assert(false, "nope") end)
  H.eq(ok, false)
  H.ok(tostring(err):find("nope"))
end)
