-- Benchmark 2: Short-String Table Lookup & Rehash Workload (luaH_getshortstr)
-- Tests:
--   1. Direct short-string field lookups (OP_GETTABLE / OP_GETTABUP)
--   2. Collision-chain short-string lookups on large string-keyed tables (1024+ keys)
--   3. OOP method dispatch & metatable __index chains (OP_SELF / luaT_gettm / luaV_finishget)
--   4. Dynamic string-keyed table construction & rehash (luaH_resize)

local N_DIRECT = tonumber(os.getenv("BENCH_N_DIRECT")) or 5000000
local N_LARGE  = tonumber(os.getenv("BENCH_N_LARGE"))  or 50000
local N_OOP    = tonumber(os.getenv("BENCH_N_OOP"))    or 3000000
local N_REHASH = tonumber(os.getenv("BENCH_N_REHASH")) or 8000

-- 1. Direct record field lookups
local rec = {
  alpha = 1, beta = 2, gamma = 3, delta = 4,
  epsilon = 5, zeta = 6, eta = 7, theta = 8,
  iota = 9, kappa = 10, lambda = 11, mu = 12,
  nu = 13, xi = 14, omicron = 15, pi = 16
}

local t0 = os.clock()
local sum1 = 0
for i = 1, N_DIRECT do
  sum1 = sum1 + rec.alpha + rec.beta + rec.gamma + rec.delta
              + rec.epsilon + rec.zeta + rec.eta + rec.theta
              + rec.iota + rec.kappa + rec.lambda + rec.mu
              + rec.nu + rec.xi + rec.omicron + rec.pi
end
local dt_direct = os.clock() - t0
assert(sum1 == N_DIRECT * 136)

-- 2. Large string-keyed table with collision chains (2048 keys)
local bigtab = {}
local keys = {}
for i = 1, 2048 do
  local k = string.format("field_key_%04d_attr", i)
  keys[i] = k
  bigtab[k] = i
end

local t1 = os.clock()
local sum2 = 0
for iter = 1, N_LARGE do
  for j = 1, 2048, 4 do
    sum2 = sum2 + bigtab[keys[j]] + bigtab[keys[j + 1]]
                + bigtab[keys[j + 2]] + bigtab[keys[j + 3]]
  end
end
local dt_large = os.clock() - t1
assert(sum2 > 0)

-- 3. OOP method dispatch & 2-level metatable __index lookup
local Base = {}
Base.__index = Base
function Base:compute(x)
  return self.base_val + x
end

local Derived = setmetatable({}, Base)
Derived.__index = Derived
function Derived:step(x)
  return self:compute(x) + self.mult
end

local obj = setmetatable({ base_val = 10, mult = 3, tag = "entity" }, Derived)

local t2 = os.clock()
local sum3 = 0
for i = 1, N_OOP do
  sum3 = sum3 + obj:step(i) + obj:compute(i)
end
local dt_oop = os.clock() - t2
assert(sum3 > 0)

-- 4. Table construction & rehash with short-string keys
local t3 = os.clock()
local sum4 = 0
for r = 1, N_REHASH do
  local d = {}
  for j = 1, 64 do
    local k = keys[j]
    d[k] = j + r
  end
  sum4 = sum4 + d[keys[1]] + d[keys[32]] + d[keys[64]]
end
local dt_rehash = os.clock() - t3
assert(sum4 > 0)

local total = dt_direct + dt_large + dt_oop + dt_rehash
io.write(string.format("RESULT table_direct_sec:      %.4f\n", dt_direct))
io.write(string.format("RESULT table_collision_sec:   %.4f\n", dt_large))
io.write(string.format("RESULT table_oop_index_sec:   %.4f\n", dt_oop))
io.write(string.format("RESULT table_rehash_sec:      %.4f\n", dt_rehash))
io.write(string.format("RESULT table_total_sec:       %.4f\n", total))
