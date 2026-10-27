-- Benchmark 3: Mixed End-to-End Workload (Large Resident State + Table Lookups + Temp Allocations)
collectgarbage("stop")

local NUM_ENTITIES = tonumber(os.getenv("BENCH_ENTITIES")) or 30000
local NUM_ROUNDS   = tonumber(os.getenv("BENCH_ROUNDS"))   or 200000

local ProtoEntity = {
  base_hp = 1000,
  base_atk = 50,
  base_def = 30
}
ProtoEntity.__index = ProtoEntity
function ProtoEntity:effective_power(bonus)
  return self.hp + (self.atk + bonus) * 4 - self.def
end

local world = {}
local key_pool = {}
for i = 1, 512 do
  key_pool[i] = "attr_slot_" .. i
end

for i = 1, NUM_ENTITIES do
  local attrs = {
    [key_pool[(i % 512) + 1]] = i,
    [key_pool[((i * 7) % 512) + 1]] = i * 2,
    level = (i % 100) + 1,
    zone = "zone_" .. (i % 64)
  }
  world[i] = setmetatable({
    id = i,
    hp = 1000 + (i % 500),
    atk = 50 + (i % 50),
    def = 30 + (i % 20),
    attrs = attrs
  }, ProtoEntity)
end

collectgarbage("restart")
collectgarbage("collect")
collectgarbage("step", 100)
collectgarbage("setpause", 110)
collectgarbage("setstepmul", 200)

local t0 = os.clock()
local total_score = 0
for r = 1, NUM_ROUNDS do
  local idx = (r % NUM_ENTITIES) + 1
  local ent = world[idx]
  local k1 = key_pool[(idx % 512) + 1]
  local event = {
    tick = r,
    actor = ent.id,
    delta = ent.attrs[k1] + ent.attrs.level,
    tag = ent.attrs.zone
  }
  total_score = total_score + ent:effective_power(event.delta)
end
local dt = os.clock() - t0
assert(total_score > 0)
io.write(string.format("RESULT mixed_total_sec:       %.4f\n", dt))
