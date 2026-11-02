local H = require("harness")

H.case("short strings and escapes", function()
  H.eq("a\nb", "a" .. "\n" .. "b")
  H.eq("\97", "a")
  H.eq("\x61", "a")
  H.eq("\u{61}", "a")
  H.eq("\u{1F600}", "\xF0\x9F\x98\x80")
  H.eq([[hello]], "hello")
  H.eq([=[a[[b]]c]=], "a[[b]]c")
  H.eq([==[x]=]y]==], "x]=]y")
end)

H.case("long strings preserve newlines and ignore first newline", function()
  local s = [[
line1
line2]]
  H.eq(s, "line1\nline2")
  local t = [=[
]=]
  H.eq(t, "")
end)

H.case("string length and embedding null", function()
  local s = "a\0b"
  H.eq(#s, 3)
  H.eq(s:byte(2), 0)
end)

H.case("concatenation and coercion", function()
  H.eq("a" .. "b" .. "c", "abc")
  H.eq(1 .. 2, "12")
  H.eq(tostring(1.5) .. "x", "1.5x")
end)
