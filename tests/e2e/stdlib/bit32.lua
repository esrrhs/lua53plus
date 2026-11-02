local H = require("harness")

H.case("bit32 library if present", function()
  if not bit32 then
    io.write("      (skip: bit32 not loaded)\n")
    return
  end
  H.eq(bit32.band(0xF, 0x3), 3)
  H.eq(bit32.bor(1, 2), 3)
  H.eq(bit32.bxor(0xF, 0xA), 5)
  H.eq(bit32.bnot(0), 0xffffffff)
  H.eq(bit32.lshift(1, 4), 16)
  H.eq(bit32.rshift(16, 2), 4)
  H.eq(bit32.arshift(0x80000000, 1), 0xc0000000)
  H.eq(bit32.extract(0xABCDEF, 4, 8), 0xDE)
  H.eq(bit32.replace(0xABCDEF, 0x11, 4, 8), 0xABC11F)
end)
