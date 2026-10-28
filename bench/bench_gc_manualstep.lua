-- Benchmark 4: Manual-Stepping Large-Heap Server Workload
-- Simulates a long-running service that uses manual GC stepping:
--   1. collectgarbage("stop") + threshold-triggered collectgarbage("step", 1000) loop
--   2. Startup ramp-up phase (with temporary spike allocations dropped after startup)
--   3. Continuous mutations to hot old-generation tables (write-barrier pressure)
--   4. Frequent closed-upvalue mutations across GCSpause / GCSpropagate / GCSsweep
--   5. Periodic weak-table creation and rotating medium-lived session state

local NUM_RECORDS  = tonumber(os.getenv("BENCH_MANUAL_RECORDS"))  or 60000
local STEADY_TICKS = tonumber(os.getenv("BENCH_MANUAL_TICKS"))    or 12000
local STEP_KB      = tonumber(os.getenv("BENCH_MANUAL_STEP_KB"))  or 1000
local THRESH_KB    = tonumber(os.getenv("BENCH_MANUAL_THRESH_KB")) or (16 * 1024)

io.write(string.format(
  "[bench_gc_manualstep] Ramp-up (%d resident records, step=%dKB, thresh=%dKB)...\n",
  NUM_RECORDS, STEP_KB, THRESH_KB
))

collectgarbage("stop")

local records = {}
local startup_spike = {}
local session_ring = {}
local RING_SIZE = 4000

local in_gc = false
local base_kb = collectgarbage("count")
local expected_up_seq = {}

-- Phase 1: Ramp-up (builds resident records + temporary startup spike while stepping GC)
for i = 1, NUM_RECORDS do
  local up_state = { seq = i, tag = "init_" .. (i % 256) }
  expected_up_seq[i] = i
  records[i] = {
    id = i,
    score = 1000 + (i % 500),
    x = i * 1.5,
    y = i * 2.5,
    items = { i, i + 1, i + 2, i + 3, label = "item_" .. (i % 128) },
    props = { a = i % 100, b = (i * 3) % 100, c = (i * 7) % 100 },
    hot_slot = { tick = 0 },
    mutate_upval = function(v)
      if v ~= nil then up_state = v end
      return up_state.seq
    end
  }
  if i % 3 == 0 then
    startup_spike[i] = { buf = "spike_" .. (i % 512), list = { i, i * 2, i * 3 } }
  end

  if i % 200 == 0 then
    if in_gc then
      if collectgarbage("step", STEP_KB) then
        in_gc = false
        base_kb = collectgarbage("count")
      end
    elseif collectgarbage("count") - base_kb >= THRESH_KB then
      in_gc = true
    end
  end
end

-- Drop temporary startup spike objects
startup_spike = nil

-- Finish any in-progress ramp-up cycle and establish post-ramp baseline
while not collectgarbage("step", STEP_KB) do end
base_kb = collectgarbage("count")
local initial_base_mb = base_kb / 1024.0
in_gc = false

local t_steady_start = os.clock()
local gc_cpu_total = 0.0
local max_step_ms = 0.0
local step_times = {}
local cycle_stats = {}
local cur_cycle_cpu = 0.0
local cur_cycle_max_step = 0.0
local cur_cycle_steps = 0
local acc = 0

-- Phase 2: Steady-state manual-stepping loop
for tick = 1, STEADY_TICKS do
  -- 1. Mutate 40 hot old record tables & 4 closed upvalues per tick
  local base_idx = ((tick * 41) % (NUM_RECORDS - 45)) + 1
  for k = 0, 39 do
    local idx = base_idx + k
    local rec = records[idx]
    local msg = { seq = tick + k, payload = tick * 3, tag = "m_" .. ((tick + k) % 256) }
    rec.hot_slot = msg
    rec.items[1] = tick + k
    if k < 4 then
      expected_up_seq[idx] = msg.seq
      acc = acc + rec.mutate_upval(msg)
    end
    acc = acc + rec.score + rec.props.a
  end

  -- 2. Periodic young weak table creation
  if tick % 8 == 0 then
    local wt = setmetatable({ ref = records[base_idx].hot_slot }, { __mode = "v" })
    if wt.ref then acc = acc + wt.ref.seq end
  end

  -- 3. Rotating medium-lived session state
  local ring_slot = (tick % RING_SIZE) + 1
  session_ring[ring_slot] = {
    sid = tick,
    token = { str = "tok_" .. (tick % 512), ttl = tick + 3600 },
    metrics = { a = tick, b = tick + 1 }
  }

  -- 4. Manual GC scheduler: wait for +THRESH_KB growth, then step(STEP_KB) until cycle finishes
  if in_gc then
    local s0 = os.clock()
    local done = collectgarbage("step", STEP_KB)
    local dt_ms = (os.clock() - s0) * 1000.0
    gc_cpu_total = gc_cpu_total + dt_ms
    cur_cycle_cpu = cur_cycle_cpu + dt_ms
    cur_cycle_steps = cur_cycle_steps + 1
    if dt_ms > cur_cycle_max_step then cur_cycle_max_step = dt_ms end
    if dt_ms > max_step_ms then max_step_ms = dt_ms end
    step_times[#step_times + 1] = dt_ms

    if done then
      in_gc = false
      base_kb = collectgarbage("count")
      cycle_stats[#cycle_stats + 1] = {
        cpu_ms = cur_cycle_cpu,
        max_step_ms = cur_cycle_max_step,
        steps = cur_cycle_steps,
        post_mb = base_kb / 1024.0
      }
      cur_cycle_cpu = 0.0
      cur_cycle_max_step = 0.0
      cur_cycle_steps = 0
    end
  else
    if collectgarbage("count") - base_kb >= THRESH_KB then
      in_gc = true
    end
  end
end

local steady_wall_sec = os.clock() - t_steady_start

-- Verify data integrity of resident records and closed upvalues after all GC cycles
for i = 1, NUM_RECORDS, 97 do
  local rec = records[i]
  assert(rec.id == i and rec.score == 1000 + (i % 500), "resident record corrupted")
  assert(rec.mutate_upval(nil) == expected_up_seq[i], "closed upvalue state corrupted across GC")
end

table.sort(step_times)
local p99_step_ms = #step_times > 0 and step_times[math.max(1, math.floor(#step_times * 0.99))] or 0
local avg_cycle_ms = 0
local min_post_mb, max_post_mb = 1e9, 0
for _, c in ipairs(cycle_stats) do
  avg_cycle_ms = avg_cycle_ms + c.cpu_ms
  if c.post_mb < min_post_mb then min_post_mb = c.post_mb end
  if c.post_mb > max_post_mb then max_post_mb = c.post_mb end
end
if #cycle_stats > 0 then avg_cycle_ms = avg_cycle_ms / #cycle_stats end

assert(acc > 0)
assert(#cycle_stats >= 2, "expected at least 2 manual GC cycles to complete")
-- Verify heap stays bounded and does not grow unboundedly over initial baseline
assert(min_post_mb <= initial_base_mb * 1.25,
  string.format("post-GC baseline drifted too high: %.1fMB vs initial %.1fMB", min_post_mb, initial_base_mb))

io.write(string.format(
  "RESULT manualstep_summary: cycles=%d avg_cycle_ms=%.1f total_gc_ms=%.1f step_p99_ms=%.2f max_step_ms=%.2f post_gc_mb=%.1f..%.1f wall_sec=%.2f\n",
  #cycle_stats, avg_cycle_ms, gc_cpu_total, p99_step_ms, max_step_ms,
  min_post_mb, max_post_mb, steady_wall_sec
))
for idx, c in ipairs(cycle_stats) do
  io.write(string.format("  cycle #%02d: cpu=%6.1fms  max_step=%5.2fms  steps=%3d  post_gc=%.1fMB\n",
    idx, c.cpu_ms, c.max_step_ms, c.steps, c.post_mb))
end
