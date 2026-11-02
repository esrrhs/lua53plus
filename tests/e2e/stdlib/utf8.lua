local H = require("harness")

H.case("utf8 len codes char", function()
  H.eq(utf8.len("abc"), 3)
  H.eq(utf8.len("你好"), 2)
  H.eq(utf8.char(0x4F60, 0x597D), "你好")
  local codes = {}
  for _, c in utf8.codes("A你") do codes[#codes+1] = c end
  H.eq(codes[1], 65)
  H.eq(codes[2], 0x4F60)
end)

H.case("utf8 offset codepoint", function()
  local s = "a你好"
  H.eq(utf8.offset(s, 2), 2)
  H.eq(utf8.codepoint(s, 2), 0x4F60)
  H.eq(utf8.charpattern ~= nil, true)
end)
