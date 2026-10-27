-- Benchmark 1: Large-Heap Incremental GC Workload (propagatemark & sweeplist)
-- Builds a large resident old-generation object graph (~300,000 live tables/strings/closures)
-- and then executes high-rate short-lived request allocations under incremental GC.

local RESIDENT_GROUPS = tonumber(os.getenv("BENCH_RESIDENT_GROUPS")) or 50000
local TICKS_DEFAULT   = tonumber(os.getenv("BENCH_TICKS_DEFAULT"))   or 500000
local TICKS_LOWPAUSE  = tonumber(os.getenv("BENCH_TICKS_LOWPAUSE"))  or 500000

io.write(string.format("[bench_gc_largeheap] Building resident heap (%d groups)...\n", RESIDENT_GROUPS))
collectgarbage("stop")

local resident = {}
for i = 1, RESIDENT_GROUPS do
  local k1 = "cfg_key_alpha_" .. (i % 1024)
  local k2 = "cfg_key_beta_"  .. (i % 1024)
  local k3 = "cfg_key_gamma_" .. (i % 1024)
  local sub1 = { id = i, [k1] = i * 10, [k2] = "val_" .. (i % 512), flag = true }
  local sub2 = { [k2] = sub1, [k3] = { i, i + 1, i + 2, i + 3 } }
  local sub3 = { name = k1, ref = sub2, weight = i * 0.5 }
  resident[i] = {
    primary = sub1,
    secondary = sub2,
    tertiary = sub3,
    fn = function(x) return sub1.id + x end
  }
end

collectgarbage("restart")
collectgarbage("collect")

-- Warm up 1 incremental cycle so resident objects are promoted to oldgen
collectgarbage("setpause", 110)
collectgarbage("setstepmul", 200)
for w = 1, 20000 do
  local tmp = { a = w, b = w + 1 }
  if tmp.a < 0 then break end
end

local mem_kb = collectgarbage("count")
io.write(string.format("[bench_gc_largeheap] Resident heap live size: %.2f MB\n", mem_kb / 1024.0))

-- Phase A: Standard GC parameters (pause = 150, stepmul = 200)
collectgarbage("setpause", 150)
collectgarbage("setstepmul", 200)

local t0 = os.clock()
local acc = 0
for tick = 1, TICKS_DEFAULT do
  local req = {
    req_id = tick,
    session = "sess_" .. (tick % 256),
    payload = { a = tick, b = tick + 1, c = tick + 2, d = tick + 3 },
    meta = { trace = tick * 3, ok = true }
  }
  local entry = resident[(tick % RESIDENT_GROUPS) + 1]
  acc = acc + entry.primary.id + req.payload.a + req.meta.trace
end
local t1 = os.clock()
local dt_default = t1 - t0

-- Phase B: Server low-pause GC parameters (pause = 110, stepmul = 200)
-- Common in production services to bound memory overhead on large heaps.
collectgarbage("setpause", 110)
collectgarbage("setstepmul", 200)

local t2 = os.clock()
for tick = 1, TICKS_LOWPAUSE do
  local req = {
    req_id = tick,
    session = "sess_" .. (tick % 256),
    payload = { a = tick, b = tick + 1, c = tick + 2, d = tick + 3 },
    meta = { trace = tick * 3, ok = true }
  }
  local entry = resident[(tick % RESIDENT_GROUPS) + 1]
  acc = acc + entry.primary.id + req.payload.b + req.meta.trace
end
local t3 = os.clock()
local dt_lowpause = t3 - t2

-- Phase C: GC step pause latency distribution (1000 server ticks with explicit GC step)
local NUM_SAMPLES = 1000
local pauses = {}
for i = 1, NUM_SAMPLES do pauses[i] = 0 end
for s = 1, NUM_SAMPLES do
  for j = 1, 50 do
    local tick = s * 50 + j
    local req = {
      req_id = tick,
      payload = { a = tick, b = tick + 1, c = tick + 2, d = tick + 3 }
    }
    acc = acc + req.payload.a
  end
  local p0 = os.clock()
  collectgarbage("step", 64)
  local p1 = os.clock()
  pauses[s] = (p1 - p0) * 1e6
end
table.sort(pauses)
local sum_p = 0
for i = 1, NUM_SAMPLES do sum_p = sum_p + pauses[i] end
local avg_us = sum_p / NUM_SAMPLES
local p99_us = pauses[math.floor(NUM_SAMPLES * 0.99)]
local max_us = pauses[NUM_SAMPLES]

assert(acc > 0)
io.write(string.format("RESULT gc_standard_pause_sec: %.4f (%.0f req/s)\n", dt_default, TICKS_DEFAULT / dt_default))
io.write(string.format("RESULT gc_low_pause_sec:      %.4f (%.0f req/s)\n", dt_lowpause, TICKS_LOWPAUSE / dt_lowpause))
io.write(string.format("RESULT gc_total_sec:          %.4f\n", dt_default + dt_lowpause))
io.write(string.format("RESULT gc_step_pause_us:      avg=%.1f p99=%.1f max=%.1f\n", avg_us, p99_us, max_us))
