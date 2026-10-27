# lua53plus

[![CI](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml/badge.svg)](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml)

[中文文档 (README_CN.md)](./README_CN.md)

**`lua53plus`** is a high-performance, 100% C API / ABI drop-in compatible enhancement of **PUC-Lua 5.3.4** written in pure single-threaded C.

It is engineered for long-running C/C++ services and game/application servers that embed Lua 5.3 with a **large resident heap** (hundreds of megabytes of long-lived configuration tables, function prototypes, closures, and persistent state) while continuously processing high-frequency requests that allocate short-lived objects and perform intensive string-keyed table lookups.

---

## Why `lua53plus`?

In standard PUC-Lua 5.3.4, the incremental mark-and-sweep garbage collector (`lgc.c`) is non-generational (the nursery generational collector introduced experimentally in Lua 5.2 was removed in Lua 5.3.0). When a Lua VM holds a large resident heap (e.g., 50 MB – 500 MB of long-lived objects):

1. **`propagatemark` & `sweeplist` Dominate CPU (~30%+ CPU Overhead):**
   Every single incremental GC cycle must re-traverse (`propagatemark` / `traversestrongtable`) and re-sweep (`sweeplist`) the entire `allgc` list of millions of long-lived objects just to reclaim a few megabytes of newly allocated request temporaries.
2. **Multi-Millisecond GC Latency Spikes:**
   Transitioning through atomic/sweep phases or running aggressive low-pause GC steps (`setpause <= 110`) causes severe cache thrashing across the resident heap and multi-millisecond frame stalls (up to 10–30 ms). Even in Lua 5.4's generational mode (`KGC_GEN`), falling back to a Major GC (`fullgen`) executes a synchronous stop-the-world full collection.
3. **`luaH_getshortstr` & `luaH_get` Call/Branch Overhead:**
   In standard PUC-Lua 5.3.4, every VM table lookup (`OP_GETTABLE`, `OP_GETTABUP`, `OP_SELF`, `luaV_finishget`, `luaT_gettm`) dispatches through out-of-line `luaH_get` / `luaH_getstr` / `luaH_getshortstr` functions, checking the type tag before the interned pointer and incurring call overhead on every primary-bucket hit.

`lua53plus` eliminates these bottlenecks directly inside the standard Lua 5.3.4 codebase **without external dependencies, without breaking C ABI, `lua_State` / `TValue` / `Table` struct layouts, or precompiled bytecode compatibility**.

---

## Key Optimizations

### 1. Old-Generation GC Isolation (`oldgc`), Write Barriers & 100% Incremental Major GC (`src/lgc.c`, `src/lgc.h`, `src/lstate.h`)
- **Two-Generation List Partitioning (`allgc` vs. `oldgc`):**
  When entering the sweep phase (`entersweep`) of an incremental GC cycle, `lua53plus` detaches the current young list (`allgc` -> `tobeswept`, `finobj` -> `tobesweptfin`) and resets `allgc = NULL` so newly allocated objects go cleanly into the young generation.
- **`sweeptobeswept` Promotion:**
  During incremental sweep, dead young objects in `tobeswept` are freed immediately, while surviving objects are promoted into `g->oldgc` (or `g->oldfinobj`) with `BLACKBIT | OLDBIT` set.
- **Zero-Cost Old-Gen Skipping in Minor Cycles:**
  Because promoted objects in `g->oldgc` remain marked `BLACKBIT | OLDBIT` across minor cycles and are isolated from `g->allgc`:
  - `propagatemark` automatically skips them (`iswhite(o)` is false).
  - `sweeptobeswept` never scans `g->oldgc` at all, reducing sweep complexity from $O(\text{Total Heap})$ to $O(\text{Young Nursery})$.
- **Write-Barrier & Weak/Thread Tracking:**
  - When a black old object is mutated to reference a white young object (`luaC_barrier_` / `luaC_barrierback_`), the barrier marks the container with `TOUCHEDBIT` and links it onto `g->grayagain` (or records the target in bounded remembered-set buffer `g->rembuf` for userdata/upvalue barriers outside the mark phase).
  - At the start of the next minor cycle (`restartcollection`), `g->gray` is seeded directly from `g->grayagain`, `g->oldweak` (surviving threads and weak tables), and `g->rembuf`, re-traversing only mutated old containers and roots.
- **100% Incremental Step-by-Step Major GC (`startbleach` / `bleachstep`):**
  - Unlike Lua 5.4's generational collector where a Major GC (`fullgen`) performs a synchronous stop-the-world pass, `lua53plus` executes Major GC **100% incrementally from start to finish**.
  - When an incremental cycle triggers a Major GC (e.g., when `oldcount > lastmajcount * 1.5` or weak-mode metatables are dynamically attached to old tables), `GCSpause` enters an incremental bleaching phase (`g->inbleach = 1`).
  - Each `singlestep` (`bleachstep`) bleaches at most `GCSWEEPMAX` objects from the head of `g->oldgc` / `g->oldfinobj` back to `luaC_white(g)` and splices them onto `g->allgc` / `g->finobj` in $O(1)$ time with software prefetching (`l_prefetch`), avoiding any synchronous full-list walk before transitioning into `restartcollection` $\to$ `GCSpropagate` $\to$ `GCSatomic` $\to$ `entersweep`.

### 2. Inlined `luaH_fastgetshortstr` & Cache-Local Collision Chains (`src/ltable.h`, `src/ltable.c`, `src/lvm.c`, `src/ltm.c`)
- **Header-Inlined Fast-Path (`luaH_fastgetshortstr`, `luaH_fastgetstr`, `luaH_fastget`):**
  Inlines the short-string hash lookup and integer array-bounds check directly into `lvm.c`, `lapi.c`, and `ltm.c`.
- **Pointer-First Interned Short-String Comparison:**
  Since short strings (`LUA_TSHRSTR`) are uniquely interned in Lua 5.3, comparing `val_(k).gc == obj2gco(key)` first (before checking `ttisshrstring(k)`) rejects non-matching keys in a single 64-bit register comparison and eliminates branch mispredictions on string-keyed tables.
- **Cache-Line Buddy Probing (`getfreepos`):**
  When inserting colliding keys in `luaH_newkey`, `getfreepos` first probes buddy slots (`idx ^ 1`, `idx ^ 2`, `idx ^ 3`) within the same 64B/128B CPU cache line before falling back to the reverse `lastfree` scan, keeping collision chains within L1/L2 cache lines.
- **Direct Rehash Insertion (`luaH_resize`):**
  During table growth/rehash, existing non-nil entries are inserted directly via array slot or `luaH_newkey` without redundant `luaH_get` searches.

---

## Benchmark Results

All benchmarks are located in [`bench/`](./bench/) and compare clean **PUC-Lua 5.3.4** (`a4f7d29`) against **`lua53plus`** (compiled with `gcc -O2` on Linux x86_64):

### 1. Large Resident Heap Throughput & GC Pause Latency (`bench/bench_gc_largeheap.lua`)

Simulates a server VM holding a large resident object graph (long-lived tables, strings, and closures) while continuously allocating short-lived per-request tables (`req`, `payload`, `meta`) and looking up resident config entries:

| Metric | PUC-Lua 5.3.4 | `lua53plus` | Improvement |
| :--- | :---: | :---: | :---: |
| **45 MB Resident Heap — Standard Pause (`pause=150`)** | 0.4430 s (1,128K req/s) | **0.3144 s (1,590K req/s)** | **+41.0% throughput** |
| **45 MB Resident Heap — Low Pause (`pause=110`)** | 0.4260 s (1,174K req/s) | **0.3109 s (1,608K req/s)** | **+37.0% throughput** |
| **171 MB Resident Heap — Low Pause (`pause=110`, 2M reqs)** | 3.6575 s (547K req/s) | **1.5203 s (1,316K req/s)** | **2.41x throughput (-58.4% time)** |
| **GC Step Pause Latency — Average (`collectgarbage("step", 64)`)** | 19.7 µs | **2.6 µs** | **7.6x lower avg pause** |
| **GC Step Pause Latency — P99** | 150.0 µs | **65.0 µs** | **2.3x lower P99 pause** |
| **GC Step Pause Latency — Max Spike (45 MB / 171 MB heap)** | 3.85 ms / 28.73 ms | **0.53 ms / 1.89 ms** | **7.3x – 15.2x lower max pause** |

### 2. CPU Hotspot Breakdown (`perf record` on 130 MB Resident Heap Workload)

| Function / Subsystem | PUC-Lua 5.3.4 (% CPU) | `lua53plus` (% CPU) | Notes |
| :--- | :---: | :---: | :--- |
| `sweeplist` / `sweeptobeswept` | **17.12%** | **1.51%** | Old-gen objects isolated in `oldgc`; only young nursery swept |
| `propagatemark` | **11.78%** | **< 1.10%** | Old-gen objects stay `BLACKBIT \| OLDBIT` across minor cycles |
| `luaH_get` / `luaH_getshortstr` (out-of-line) | **15.95%** | **< 0.50%** | Inlined `luaH_fastget` / `luaH_fastgetshortstr` in `luaV_execute` |
| `luaV_execute` (useful VM execution) | 5.59% | **38.44%** | CPU shifted from GC & lookup overhead back to VM bytecode execution |
| **Total Elapsed Time (2M requests)** | **3.005 s (151.5 MB peak)** | **2.087 s (132.2 MB peak)** | **1.44x faster + 19.3 MB lower peak memory** |

### 3. Short-String Table Lookup & Mixed Workload (`bench/bench_table_lookup.lua`, `bench/bench_mixed_workload.lua`)

| Benchmark Sub-Test | PUC-Lua 5.3.4 | `lua53plus` | Speedup |
| :--- | :---: | :---: | :---: |
| **Direct Short-String Field Lookups (80M lookups)** | 0.5728 s | **0.4669 s** | **+22.7% faster** |
| **Large String Table (2048 keys, collision chains)** | 2.0797 s | **1.8050 s** | **+15.2% faster** |
| **OOP Method Dispatch & Metatable `__index`** | 0.3244 s | **0.2730 s** | **+18.8% faster** |
| **Dynamic String Table Rehash (`luaH_resize`)** | 0.0189 s | **0.0175 s** | **+8.0% faster** |
| **Mixed End-to-End Entity Workload (`bench_mixed_workload.lua`)** | 0.0696 s | **0.0498 s** | **+39.8% faster** |

---

## Build & Drop-In Replacement Instructions

### Building `lua53plus`

```bash
# Linux
make linux

# macOS
make macosx

# Clean build artifacts
make clean
```

This produces:
- `src/liblua.a`: Static library ready to link into your C/C++ host application
- `src/lua`: Standalone Lua 5.3.4 interpreter
- `src/luac`: Standalone Lua 5.3.4 bytecode compiler

### Drop-In Replacement in C/C++ Projects

`lua53plus` preserves 100% of the public headers (`lua.h`, `lauxlib.h`, `lualib.h`, `luaconf.h`), C ABI, build flags, and precompiled bytecode format of PUC-Lua 5.3.4:

1. Replace your project's `lua-5.3.4/src` directory (or `liblua.a`) with `lua53plus/src`.
2. Recompile — no changes to your C/C++ host code, linker flags, or Lua scripts are required.

### Running Benchmarks

```bash
./src/lua bench/bench_gc_largeheap.lua
./src/lua bench/bench_table_lookup.lua
./src/lua bench/bench_mixed_workload.lua
```

---

## License

Same as PUC-Lua 5.3.4 — [MIT License](http://www.lua.org/license.html).
