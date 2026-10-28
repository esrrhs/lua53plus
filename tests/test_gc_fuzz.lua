-- Comprehensive Randomized Cross-Generation GC & Write-Barrier Fuzz Suite
-- Exercises:
--   1. Old <-> Young table cross-references (values, keys, array part, hash part, rehash during every GC phase)
--   2. Multi-hop generational chains (old -> old -> young -> young) & repeated grayagain (TOUCHEDBIT) overwrites
--   3. Closures, Protos (p->cache reuse), and Open/Closed Upvalues across coroutines & debug.setupvalue/upvaluejoin
--   4. Weak tables (__mode = "k", "v", "kv", ephemerons) and dynamic mid-cycle setmetatable(old_tab, weak_mt)
--   5. Finalizers (__gc) attached to young, old, and tobeswept objects, resurrection into old tables,
--      and strict reverse-creation finalization order across Minor + Incremental-Bleach Major GC cycles
--   6. Both automatic incremental GC (varying pause/stepmul) and manual collectgarbage("stop") + collectgarbage("step", sz)

local debug = require("debug")
local T = rawget(_G, "T")

-- Deterministic LCG PRNG so every seed is 100% reproducible across platforms
local rng_state = 1
local function seed_rng(s)
  rng_state = s % 2147483647
  if rng_state <= 0 then rng_state = rng_state + 2147483646 end
end

local function rand_int(lo, hi)
  rng_state = (rng_state * 48271) % 2147483647
  return lo + (rng_state % (hi - lo + 1))
end

local function make_proto_factory(tag)
  local src = string.format([[
    local up_a, up_b = ...
    return function(x)
      if x == "get" then return up_a, up_b end
      up_a = x
      return %d
    end
  ]], tag)
  return assert(load(src, "proto_" .. tag))
end

-- Regression Test 1: Strict reverse-creation finalizer ordering across multiple Minor GC promotions
-- and multi-step incremental Major GC bleaching (`startbleach` + `bleachstep` + `g->fintail`).
local function test_finalizer_order_across_generations()
  io.write("  [regression: finalizer reverse-creation order across minor & incremental bleach major GC] ")
  io.flush()
  collectgarbage("stop")
  local order = {}
  local gc_mt = { __gc = function(self) order[#order + 1] = self.id end }

  local old = {}
  -- Batch 1 (1..400): promoted in Minor Cycle 1
  for i = 1, 400 do
    old[i] = setmetatable({ id = i }, gc_mt)
  end
  while not collectgarbage("step", 200) do end

  -- Batch 2 (401..800): promoted in Minor Cycle 2
  for i = 401, 800 do
    old[i] = setmetatable({ id = i }, gc_mt)
  end
  while not collectgarbage("step", 200) do end

  -- Batch 3 (801..900): created dynamically while incremental Major GC bleach (`inbleach == 1`) is active!
  setmetatable(old[800], { __mode = "v", __gc = gc_mt.__gc })
  collectgarbage("step", 0) -- enters GCSpause with inbleach == 1
  for i = 801, 900 do
    old[i] = setmetatable({ id = i }, gc_mt)
  end
  while not collectgarbage("step", 10) do
    if T then T.checkmemory() end
  end

  -- Drop all 900 objects and verify strict reverse-creation finalizer order (900 down to 1)
  old = nil
  collectgarbage("collect")
  assert(#order == 900, "Expected 900 finalizers, got " .. tostring(#order))
  for idx = 1, 900 do
    local expected_id = 901 - idx
    assert(order[idx] == expected_id,
      string.format("Finalizer order mismatch at %d: expected %d, got %d", idx, expected_id, order[idx]))
  end
  io.write("OK\n")
end

-- Regression Test 2: Cross-references mutated during incremental Major GC bleaching (`inbleach == 1`)
local function test_inbleach_cross_reference_mutations()
  io.write("  [regression: unbleached <-> bleached <-> young mutations during inbleach == 1] ")
  io.flush()
  collectgarbage("stop")

  local N = 6000
  local old = {}
  for i = 1, N do
    old[i] = { id = i, tag = "old_" .. i }
  end
  while not collectgarbage("step", 200) do end
  while not collectgarbage("step", 200) do end

  -- Trigger Major GC incremental bleaching
  setmetatable(old[2], { __mode = "v" })
  collectgarbage("step", 0) -- enters inbleach == 1

  -- Mutate both head of oldgc (already bleached to WHITE in allgc) and tail of oldgc (still BLACK in oldgc)
  -- to point to brand-new young objects and to each other!
  local y_tail = { secret = 111222333, nested = { v = 42 } }
  local y_head = { secret = 444555666, nested = { v = 84 } }
  old[1].young_ref = y_tail
  old[N].young_ref = y_head
  old[1].peer = old[N]
  old[N].peer = old[1]
  y_tail = nil
  y_head = nil

  if T then T.checkmemory() end

  -- Step through the rest of bleach, mark, and sweep incrementally
  while not collectgarbage("step", 15) do
    if T then T.checkmemory() end
  end

  assert(old[1].young_ref and old[1].young_ref.secret == 111222333)
  assert(old[1].young_ref.nested.v == 42)
  assert(old[N].young_ref and old[N].young_ref.secret == 444555666)
  assert(old[N].young_ref.nested.v == 84)
  io.write("OK\n")
end

local function run_fuzz_round(seed, manual_gc_mode, num_ops)
  seed_rng(seed)
  io.write(string.format("  [seed=%d mode=%s ops=%d] ",
    seed, manual_gc_mode and "manual_step" or "auto_inc", num_ops))
  io.flush()

  if manual_gc_mode then
    collectgarbage("stop")
  else
    collectgarbage("restart")
    collectgarbage("setpause", 105)
    collectgarbage("setstepmul", 300)
  end

  -- 1. Build initial resident pool that will be promoted to old generation
  local NUM_OLD = 300
  local old_pool = {}
  local weak_k_pool = setmetatable({}, { __mode = "k" })
  local weak_v_pool = setmetatable({}, { __mode = "v" })
  local weak_kv_pool = setmetatable({}, { __mode = "kv" })
  local resurrected = {}
  local finalized_count = 0

  for i = 1, NUM_OLD do
    local up1 = { kind = "init_up", id = i, check = i * 31 }
    local up2 = "init_str_" .. i
    local tbl = {
      id = i,
      magic = i * 100003,
      arr = { i, i + 1, i + 2, i + 3 },
      sub = { tag = "sub_" .. i, val = i * 7 },
      closure = function(cmd, newv)
        if cmd == "set" then
          up1 = newv
          up2 = tostring(newv and newv.check or 0)
        end
        return up1, up2
      end
    }
    old_pool[i] = tbl
  end

  -- Promote initial pool to old generation via two incremental cycles
  if manual_gc_mode then
    while not collectgarbage("step", 50) do end
    while not collectgarbage("step", 50) do end
  else
    collectgarbage("collect")
    collectgarbage("step", 100)
  end

  -- Shadow model tracking expected checksums for every slot in old_pool
  -- Note: expected_key_val stores ONLY numbers (never a strong Lua reference to y_key),
  -- so y_key is kept alive strictly by old_pool[idx]!
  local expected_child = {}
  local expected_key_val = {}
  local expected_upval = {}
  local co_pool = {}
  local proto_factories = {}
  for i = 1, 16 do
    proto_factories[i] = make_proto_factory(i * 13)
  end

  -- Helper to verify an old_pool entry's integrity
  local function verify_slot(idx)
    local t = old_pool[idx]
    assert(type(t) == "table", "old_pool entry corrupted")
    assert(t.id == idx and t.magic == idx * 100003, "old_pool scalar magic mismatch")
    assert(t.sub.val == idx * 7, "old_pool subtable mismatch")

    local exp_c = expected_child[idx]
    if exp_c then
      local c = t.young_child
      assert(type(c) == "table", "young_child missing or collected prematurely!")
      assert(c.secret == exp_c.secret and c.label == exp_c.label, "young_child content mismatch!")
      if exp_c.nested_secret then
        assert(c.nested and c.nested.val == exp_c.nested_secret, "nested young_child collected prematurely!")
      end
    end

    local exp_kv = expected_key_val[idx]
    if exp_kv then
      local found_k = nil
      for k, v in pairs(t) do
        if type(k) == "table" and k.is_ykey then
          assert(v == exp_kv.val_num, "young table key value mismatch!")
          assert(k.kcheck == exp_kv.kcheck, "young table key fields corrupted!")
          found_k = k
        end
      end
      assert(found_k ~= nil, "young table key in old table was prematurely collected!")
      assert(weak_k_pool[found_k] and weak_k_pool[found_k].eph_step == exp_kv.eph_step,
        "ephemeron value anchored by young table key was prematurely collected!")
    end

    local exp_u = expected_upval[idx]
    if exp_u then
      local u1, _ = t.closure("get")
      assert(type(u1) == "table" and u1.check == exp_u, "upvalue table collected prematurely!")
    end
  end

  -- Main randomized mutation & GC interleaving loop
  for step = 1, num_ops do
    local op = rand_int(1, 12)
    local idx = rand_int(1, NUM_OLD)
    local target = old_pool[idx]

    if op == 1 then
      -- Old table -> brand-new Young table (and 2-hop Young -> Young)
      local secret = step * 97 + idx
      local nested_secret = secret * 3 + 1
      local y_nested = { val = nested_secret, str = "nested_" .. tostring(step) }
      local y_obj = {
        secret = secret,
        label = "y_" .. tostring(step) .. "_" .. tostring(idx),
        nested = y_nested,
        [1] = step,
        [2] = idx
      }
      target.young_child = y_obj
      expected_child[idx] = {
        secret = secret,
        label = y_obj.label,
        nested_secret = nested_secret
      }

    elseif op == 2 then
      -- Repeatedly overwrite array & hash slots on the same old table (tests TOUCHEDBIT & grayagain) + trigger rehash
      local base_t = old_pool[idx]
      for k = 1, 8 do
        base_t[k] = { arr_elem = step + k }
        base_t["dyn_field_" .. ((step + k) % 32)] = { dyn_v = step * k }
      end
      assert(base_t[1].arr_elem == step + 1)

    elseif op == 3 then
      -- Young table used ONLY as a KEY inside an Old table (old[young_key] = val_num)
      -- plus an ephemeron entry in weak_k_pool[young_key]!
      local kcheck = step * 53 + idx
      local val_num = step * 11
      -- Clear any previous table key on `target`
      for k, _ in pairs(target) do
        if type(k) == "table" and k.is_ykey then
          target[k] = nil
        end
      end
      local y_key = { is_ykey = true, kcheck = kcheck, name = "key_" .. step }
      target[y_key] = val_num
      weak_k_pool[y_key] = { eph_step = step, back = target }
      expected_key_val[idx] = { val_num = val_num, kcheck = kcheck, eph_step = step }

    elseif op == 4 then
      -- Mutate closed upvalue of an old closure to point to a brand-new young table
      local chk = step * 199 + idx
      local y_up = { kind = "young_up", check = chk, extra = "u_" .. step }
      if rand_int(1, 2) == 1 then
        target.closure("set", y_up)
      else
        debug.setupvalue(target.closure, 1, y_up)
      end
      expected_upval[idx] = chk

    elseif op == 5 then
      -- Coroutine (lua_State thread) with open upvalues paused across GC steps
      local co_slot = (idx % 32) + 1
      local prev_co = co_pool[co_slot]
      if prev_co and coroutine.status(prev_co.co) == "suspended" then
        local ok, r1 = coroutine.resume(prev_co.co, { resume_arg = step })
        assert(ok and r1 == prev_co.expect, "coroutine open upvalue corrupted across GC!")
      end
      local expect_val = step * 41
      local co = coroutine.create(function(init_tbl)
        local open_local = { v = expect_val, ref = init_tbl }
        local function touch_open(x)
          open_local = { v = open_local.v + x, ref = open_local.ref }
          return open_local.v
        end
        local arg = coroutine.yield(touch_open(0))
        assert(type(arg) == "table")
        return touch_open(0)
      end)
      local ok, first_v = coroutine.resume(co, { init = step })
      assert(ok and first_v == expect_val)
      co_pool[co_slot] = { co = co, expect = expect_val }
      target.active_co = co

    elseif op == 6 then
      -- Old Proto instantiating closures & reusing p->cache
      local pf = proto_factories[(step % #proto_factories) + 1]
      local c1 = pf({ a = step }, "b_" .. step)
      local c2 = pf({ a = step + 1 }, "b_" .. step)
      local v1 = c1("get")
      assert(v1.a == step)
      target.cached_cl = c2

    elseif op == 7 then
      -- Weak tables (ephemeron k, weak v, all-weak kv) + dynamic mid-cycle weak metatable on old table
      local live_k = { lk = step }
      local live_v = { lv = step * 2 }
      target.weak_anchor_k = live_k
      target.weak_anchor_v = live_v
      weak_k_pool[live_k] = { anchored_by_key = step, child = { s = "ephemeron_" .. step } }
      weak_v_pool[step % 64] = live_v
      weak_kv_pool[{ dead_k = step }] = { dead_v = step }

      if rand_int(1, 8) == 1 then
        local dyn_old = target.dyn_weak_tab
        if not dyn_old then
          dyn_old = { a = { x = 1 }, b = { y = 2 } }
          target.dyn_weak_tab = dyn_old
        else
          local modes = { "k", "v", "kv" }
          setmetatable(dyn_old, { __mode = modes[rand_int(1, 3)] })
          dyn_old[{}] = { temp = step }
        end
      end

    elseif op == 8 then
      -- Finalizers (__gc) on young tables, old tables, and resurrecting finalizers
      local fin_mode = rand_int(1, 3)
      local gc_mt = {
        __gc = function(self)
          finalized_count = finalized_count + 1
          assert(self.fin_magic == 777777, "__gc object corrupted before finalizer!")
          local tmp_in_gc = { allocated_in_gc = finalized_count }
          if self.resurrect_slot and old_pool[self.resurrect_slot] then
            resurrected[self.resurrect_slot] = self
            old_pool[self.resurrect_slot].resurrected_obj = tmp_in_gc
          end
        end
      }
      if fin_mode == 1 then
        setmetatable({ fin_magic = 777777, resurrect_slot = (step % 5 == 0) and idx or nil }, gc_mt)
      elseif fin_mode == 2 then
        local old_candidate = target.future_fin_obj
        if old_candidate and not getmetatable(old_candidate) then
          old_candidate.fin_magic = 777777
          setmetatable(old_candidate, gc_mt)
          target.future_fin_obj = nil
        else
          target.future_fin_obj = { fin_magic = 777777, born = step }
        end
      else
        if target.tobeswept_fin and not getmetatable(target.tobeswept_fin) then
          target.tobeswept_fin.fin_magic = 777777
          setmetatable(target.tobeswept_fin, gc_mt)
          target.tobeswept_fin = nil
        else
          target.tobeswept_fin = { fin_magic = 777777, step = step }
        end
      end

    elseif op == 9 then
      -- Multi-hop chain: Old1 -> Old2 -> Young1 -> Young2
      local idx2 = rand_int(1, NUM_OLD)
      local t2 = old_pool[idx2]
      local y2 = { hop = 2, val = step * 17 }
      local y1 = { hop = 1, next_hop = y2 }
      t2.chain_head = y1
      target.peer_old = t2
      assert(target.peer_old.chain_head.next_hop.val == step * 17)

    elseif op == 10 then
      -- Join upvalues between two closures (debug.upvaluejoin -> lua_upvaluejoin)
      local idx2 = rand_int(1, NUM_OLD)
      if idx2 ~= idx then
        local function dummy_cl()
          local local_u = { joined = true, check = step * 29 }
          return function() return local_u end
        end
        local donor = dummy_cl()
        debug.upvaluejoin(target.closure, 1, donor, 1)
        expected_upval[idx] = step * 29
      end

    elseif op == 11 then
      -- Drop some references to create dead old & young garbage (including dead keys in old tables!)
      local drop_idx = rand_int(1, NUM_OLD)
      local dt = old_pool[drop_idx]
      dt.young_child = nil
      expected_child[drop_idx] = nil
      if expected_key_val[drop_idx] then
        for k, _ in pairs(dt) do
          if type(k) == "table" and k.is_ykey then
            dt[k] = nil
          end
        end
        expected_key_val[drop_idx] = nil
      end

    elseif op == 12 then
      -- Verify a random slice of old_pool entries
      for _ = 1, 10 do
        verify_slot(rand_int(1, NUM_OLD))
      end
    end

    -- Interleave GC stepping
    if manual_gc_mode then
      if step % 3 == 0 then
        local step_sz = rand_int(0, 64)
        collectgarbage("step", step_sz)
        if T and step % 150 == 0 then T.checkmemory() end
      end
      if step % 750 == 0 then
        collectgarbage("setpause", rand_int(90, 160))
        collectgarbage("setstepmul", rand_int(150, 400))
      end
    else
      if step % 40 == 0 then
        collectgarbage("step", rand_int(0, 32))
        if T and step % 200 == 0 then T.checkmemory() end
      end
    end
  end

  -- Final verification of ALL slots before and after full GC
  for i = 1, NUM_OLD do
    verify_slot(i)
  end

  if manual_gc_mode then
    for _ = 1, 2 do
      while not collectgarbage("step", 64) do end
    end
  end
  collectgarbage("collect")
  collectgarbage("collect")
  if T then T.checkmemory() end

  for i = 1, NUM_OLD do
    verify_slot(i)
  end

  for slot, robj in pairs(resurrected) do
    assert(robj.fin_magic == 777777 and slot >= 1)
  end
  assert(finalized_count > 0, "expected finalizers to have executed")

  -- Drop all state and verify memory reclaims cleanly
  for i = 1, NUM_OLD do
    old_pool[i] = nil
    expected_child[i] = nil
    expected_key_val[i] = nil
    expected_upval[i] = nil
  end
  resurrected = nil
  co_pool = nil
  collectgarbage("collect")
  collectgarbage("collect")
  if T then T.checkmemory() end
  local final_kb = collectgarbage("count")
  io.write(string.format("OK (finalized=%d, post_gc_kb=%.1f)\n", finalized_count, final_kb))
end

-- Regression Test 3: Edge cases across lundump, tobeswept/tobefnz barriers, and TM_HASMODE fastset
local function test_gc_adversarial_edge_cases()
  io.write("  [regression: stripped undump barrier, tobeswept/tobefnz barriers & TM_HASMODE fastset] ")
  io.flush()

  -- 3a. Stripped precompiled chunk with GC triggered inside lua_Reader while Proto is black & source is NULL
  local dumped = string.dump(function(x)
    local a = x + 1
    return function() return a end
  end, true)
  for split = 28, math.min(#dumped - 1, 64) do
    local chunk_idx = 0
    local fn = assert(load(function()
      chunk_idx = chunk_idx + 1
      if chunk_idx == 1 then return dumped:sub(1, split) end
      if chunk_idx == 2 then
        collectgarbage("collect")
        return dumped:sub(split + 1)
      end
      return nil
    end))
    assert(fn(41)() == 42)
  end

  -- Build >4MB resident old heap so minor cycles stay minor unless needmajor is triggered
  local resident = {}
  for i = 1, 80000 do resident[i] = { i, i + 1, i + 2 } end
  collectgarbage("collect")

  -- 3b. Weak table in tobeswept gets a brand-new white __gc metatable during GCSswpallgc
  do
    local weak_mt = { __mode = "v" }
    local o = setmetatable({}, weak_mt)
    local pad = {}
    for i = 1, 2000 do pad[i] = { i } end
    setmetatable({}, { __gc = function()
      setmetatable(o, {
        tag = "alive_meta_tag",
        __gc = function() end
      })
    end })
    for _ = 1, 5000 do
      if getmetatable(o) ~= weak_mt then break end
      collectgarbage("step", 0)
    end
    assert(getmetatable(o) ~= weak_mt)
    while not collectgarbage("step", 0) do end
    while not collectgarbage("step", 0) do end
    assert(getmetatable(o) and getmetatable(o).tag == "alive_meta_tag")
  end

  -- 3c. Peer table in tobefnz mutated by earlier finalizer during GCSswpallgc
  do
    local resurrected_b = nil
    local B = setmetatable({ name = "B" }, { __gc = function(self) resurrected_b = self end })
    local A = setmetatable({ peer = B }, { __gc = function(self)
      self.peer.child = { "white_child_in_tobefnz" }
    end })
    local pad = {}
    for i = 1, 2000 do pad[i] = { i } end
    A, B = nil, nil
    while not collectgarbage("step", 0) do end
    while not collectgarbage("step", 0) do end
    assert(resurrected_b and resurrected_b.child and resurrected_b.child[1] == "white_child_in_tobefnz")
  end

  -- 3d. Table in tobeswept assigned an already-old black weak metatable during GCSswpallgc
  do
    local old_weak_mt = { __mode = "v" }
    collectgarbage("collect")
    local val = { "collect_me" }
    local o = { v = val }
    local pad = {}
    for i = 1, 2000 do pad[i] = { i } end
    local assigned = false
    setmetatable({}, { __gc = function()
      assigned = true
      setmetatable(o, old_weak_mt)
    end })
    while not assigned do collectgarbage("step", 0) end
    while not collectgarbage("step", 0) do end
    val = nil
    while not collectgarbage("step", 0) do end
    assert(o.v == nil)
  end

  -- 3e. Existing non-nil mt.__mode mutated in-place via luaV_fastset (TM_HASMODE)
  do
    local v_str = "v"
    local mt = { __mode = false }
    local val = { "collect_me_fastset" }
    local o = setmetatable({ v = val }, mt)
    collectgarbage("collect")
    mt.__mode = v_str
    val = nil
    while not collectgarbage("step", 0) do end
    assert(o.v == nil)
  end

  -- 3f. Finalization order when object in tobeswept is given __gc during GCSswpallgc after finobj/tobesweptfin
  do
    local order = {}
    local A = setmetatable({ name = "A" }, { __gc = function() order[#order + 1] = "A" end })
    local B = { name = "B" }
    local pad = {}
    for i = 1, 2000 do pad[i] = { i } end
    local registered_b = false
    setmetatable({}, { __gc = function()
      registered_b = true
      setmetatable(B, { __gc = function() order[#order + 1] = "B" end })
    end })
    while not registered_b do collectgarbage("step", 0) end
    while not collectgarbage("step", 0) do end
    A, B = nil, nil
    collectgarbage("collect")
    assert(order[1] == "B" and order[2] == "A")
  end

  resident = nil
  collectgarbage("collect")
  io.write("OK\n")
end

-- Regression Test 4: High-volume closed-upvalue & userdata barriers during pause/sweep + incremental grayagain drain
local function test_heavy_upval_and_grayagain_drain()
  io.write("  [regression: unbounded remuv/remudata barriers & incremental grayagain drain] ")
  io.flush()
  collectgarbage("stop")

  local closures = {}
  local tables = {}
  for i = 1, 500 do
    local up = { val = i }
    closures[i] = function(newv)
      if newv ~= nil then up = newv end
      return up
    end
    tables[i] = { id = i, slot = { x = i } }
  end

  -- Promote to old generation
  while not collectgarbage("step", 200) do end
  while not collectgarbage("step", 200) do end

  -- While sitting in GCSpause, mutate >500 closed upvalues (>64 old rembuf limit),
  -- create young weak tables, and dirty all 500 old tables multiple times
  local wt_list = {}
  for round = 1, 4 do
    for i = 1, 500 do
      closures[i]({ val = i * 10 + round, tag = "up_" .. i })
      tables[i].slot = { x = i * 100 + round }
    end
    wt_list[round] = setmetatable({ ref = tables[round].slot }, { __mode = "v" })
  end

  if T then T.checkmemory() end

  -- Step through the cycle incrementally and verify all values survive intact
  while not collectgarbage("step", 16) do
    if T then T.checkmemory() end
  end

  for i = 1, 500 do
    local u = closures[i]()
    assert(type(u) == "table" and u.val == i * 10 + 4, "closed upvalue lost across minor GC!")
    assert(tables[i].slot and tables[i].slot.x == i * 100 + 4, "old table slot lost across minor GC!")
  end
  for round = 1, 3 do
    assert(wt_list[round].ref == nil, "overwritten weak value should be collected!")
  end
  assert(wt_list[4].ref and wt_list[4].ref.x == 404)

  collectgarbage("restart")
  collectgarbage("collect")
  io.write("OK\n")
end

print("=== Running Randomized Cross-Generation GC Fuzz Suite ===")
test_heavy_upval_and_grayagain_drain()
test_finalizer_order_across_generations()
test_inbleach_cross_reference_mutations()
test_gc_adversarial_edge_cases()

local NUM_OPS = tonumber(os.getenv("FUZZ_OPS")) or 4000
local seeds = { 101, 2026, 31415, 65537, 999983, 133742, 7777777, 42424242 }
for idx, s in ipairs(seeds) do
  local manual = (idx % 2 == 1)
  run_fuzz_round(s, manual, NUM_OPS)
end
print("=== All Randomized Cross-Generation GC Fuzz Tests Passed! ===")
