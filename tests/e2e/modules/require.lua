local H = require("harness")
local debug = require("debug")

local e2e = (debug.getinfo(1, "S").source:match("^@(.*)/modules/") or ".")
local fixtures = e2e .. "/fixtures/modpack"

H.case("require with package.path", function()
  local old = package.path
  package.path = fixtures .. "/?.lua;" .. fixtures .. "/?/init.lua;" .. old
  package.loaded.hello = nil
  local m = require("hello")
  H.eq(m.VERSION, 1)
  H.eq(m.greet("e2e"), "hello,e2e")
  -- cached
  local m2 = require("hello")
  H.ok(m == m2)
  package.path = old
end)

H.case("require directory init", function()
  local old = package.path
  package.path = fixtures .. "/?.lua;" .. fixtures .. "/?/init.lua;" .. old
  package.loaded.sub = nil
  local m = require("sub")
  H.eq(m.kind, "sub-init")
  H.eq(m.n, 42)
  package.path = old
end)

H.case("package.loaded caching side effects once", function()
  local old = package.path
  package.path = fixtures .. "/?.lua;" .. old
  package.loaded.side_effect = nil
  _G.__e2e_side_effect = 0
  local a = require("side_effect")
  local b = require("side_effect")
  H.eq(a.count, 1)
  H.eq(b.count, 1)
  H.eq(_G.__e2e_side_effect, 1)
  package.path = old
end)

H.case("package.searchers present", function()
  H.eq(type(package.searchers), "table")
  H.ok(#package.searchers >= 2)
  H.eq(type(package.searchpath), "function")
end)
