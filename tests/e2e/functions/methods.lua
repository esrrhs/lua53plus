local H = require("harness")

H.case("colon method sugar", function()
  local o = { n = 0 }
  function o:inc(d)
    self.n = self.n + (d or 1)
    return self.n
  end
  H.eq(o:inc(), 1)
  H.eq(o:inc(4), 5)
  H.eq(o.inc(o, 1), 6)
end)

H.case("metamethod __call as method target", function()
  local o = setmetatable({x = 1}, {
    __call = function(self, y) return self.x + y end
  })
  H.eq(o(2), 3)
end)
