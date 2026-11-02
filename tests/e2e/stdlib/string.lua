local H = require("harness")

H.case("byte find sub len rep reverse", function()
  H.eq(string.byte("ABC", 2), 66)
  H.eq(string.char(65, 66), "AB")
  H.eq(string.sub("abcdef", 2, 4), "bcd")
  H.eq(string.rep("ab", 3), "ababab")
  H.eq(string.reverse("abc"), "cba")
  H.eq(string.upper("aB"), "AB")
  H.eq(string.lower("aB"), "ab")
  local i, j = string.find("hello", "ll")
  H.eq(i, 3); H.eq(j, 4)
end)

H.case("format patterns", function()
  H.eq(string.format("%d-%s", 3, "x"), "3-x")
  H.eq(string.format("%02d", 7), "07")
  H.eq(string.format("%.2f", 1.5), "1.50")
  H.eq(string.format("%q", "a\nb"), '"a\\\nb"')
end)

H.case("gsub gmatch match", function()
  H.eq(("a_b_c"):gsub("_", "-"), "a-b-c")
  local n = 0
  for w in ("one two"):gmatch("%w+") do n = n + 1 end
  H.eq(n, 2)
  H.eq(string.match("id=42", "id=(%d+)"), "42")
end)

H.case("pack unpack", function()
  local s = string.pack("i4", 0x12345678)
  H.eq(#s, 4)
  H.eq(string.unpack("i4", s), 0x12345678)
  local u = string.pack("z", "hi")
  H.eq(string.unpack("z", u), "hi")
end)

H.case("dump of function", function()
  local f = function() return 1 end
  H.ok(#string.dump(f) > 10)
end)
