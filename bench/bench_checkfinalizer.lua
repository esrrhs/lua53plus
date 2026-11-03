-- Microbench: attach __gc to many already-promoted old tables.
-- Exercises luaC_checkfinalizer oldgc unlink (listprev O(1) vs prior O(n)).
-- Not wired into CI (timing noise); run manually vs a baseline build.
-- Usage: ./src/lua bench/bench_checkfinalizer.lua [N]

local N = tonumber(arg and arg[1]) or tonumber(os.getenv("BENCH_CFIN_N")) or 50000

collectgarbage("stop")
local keep = {}
for i = 1, N do
  keep[i] = { i = i }
end
-- Promote into oldgc
while not collectgarbage("step", 200) do end
while not collectgarbage("step", 200) do end

local mt = { __gc = function() end }
local t0 = os.clock()
for i = 1, N do
  setmetatable(keep[i], mt)
end
local t1 = os.clock()
local elapsed = t1 - t0
io.write(string.format("checkfinalizer_oldgc N=%d elapsed=%.4fs (%.0f ns/op)\n",
  N, elapsed, (elapsed / N) * 1e9))

-- Sanity: finalizers should run after drop
local count = 0
mt.__gc = function() count = count + 1 end
-- re-set to install counting finalizer (already finalized bit set — skip)
-- Instead drop and collect: objects already have FINALIZEDBIT from first setmetatable
keep = nil
collectgarbage("collect")
io.write(string.format("finalizers_ran=%d (expect ~%d)\n", count, N))
-- Note: first setmetatable already moved them to finobj; __gc from first mt is empty.
-- Recount with a fresh batch:
collectgarbage("stop")
keep = {}
local mt2 = { __gc = function() count = count + 1 end }
count = 0
for i = 1, math.min(N, 5000) do
  keep[i] = setmetatable({ i = i }, mt2)
end
while not collectgarbage("step", 200) do end
keep = nil
collectgarbage("collect")
io.write(string.format("fresh_batch_finalizers=%d\n", count))
collectgarbage("restart")
