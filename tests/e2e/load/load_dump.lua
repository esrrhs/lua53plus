local H = require("harness")

H.case("load string modes", function()
  local f = assert(load("return 1+2", "t1", "t"))
  H.eq(f(), 3)
  local bin = string.dump(f)
  H.ok(type(bin) == "string" and #bin > 0)
  local g = assert(load(bin, "b1", "b"))
  H.eq(g(), 3)
  -- text rejected as binary
  local bad, err = load("return 1", "x", "b")
  H.eq(bad, nil)
  H.ok(err and err:find("text"))
end)

H.case("dump/undump roundtrip with upvalues stripped", function()
  local function maker()
    local x = 7
    return function() return x end
  end
  local cl = maker()
  H.eq(cl(), 7)
  local dumped = string.dump(cl)
  local restored = assert(load(dumped, "rt", "b"))
  -- dumped closure loses upvalue content (nil or error on use depending);
  -- load of dump creates a function; calling may error if upvalue missing.
  H.eq(type(restored), "function")
  -- Roundtrip a closed chunk without upvalues:
  local f = assert(load("local a=1; return function(b) return a+b end"))
  local inner = f()
  H.eq(inner(2), 3)
  local d = string.dump(f)
  local f2 = assert(load(d))
  H.eq(f2()(5), 6)
end)

H.case("loadfile temp", function()
  local path = os.tmpname()
  local fh = assert(io.open(path, "w"))
  fh:write("return 40 + 2\n")
  fh:close()
  local f = assert(loadfile(path))
  H.eq(f(), 42)
  os.remove(path)
end)

H.case("load reader function", function()
  local parts = {"ret", "urn ", "21"}
  local i = 0
  local f = assert(load(function()
    i = i + 1
    return parts[i]
  end))
  H.eq(f(), 21)
end)
