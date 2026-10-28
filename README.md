# lua53plus

[![CI](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml/badge.svg)](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml)

[中文文档 (README_CN.md)](./README_CN.md)

**`lua53plus`** is a high-performance, 100% C API / ABI drop-in compatible enhancement of **PUC-Lua 5.3.4** written in pure single-threaded C.

It is engineered for long-running C/C++ services and game/application servers that embed Lua 5.3 with a **large resident heap** (hundreds of megabytes of long-lived configuration tables, function prototypes, closures, and persistent state) while continuously processing high-frequency requests that allocate short-lived objects and perform intensive string-keyed table lookups.

---

## How `lua53plus` Works: A Beginner-Friendly Visual Guide to Generational GC

Even if you have never read Lua's C source code before, this section walks you through **why standard Lua 5.3 slows down on large heaps, and how `lua53plus` fixes it step by step.**

---

### Step 1: How Standard Lua 5.3.4 GC Works (And Why It Stalls on Large Heaps)

#### 1. The Single Linked List (`allgc`) and Three-Color Marking
In standard PUC-Lua 5.3.4, **every single collectable object** you create in Lua (tables, functions, strings, coroutines), whether it was created 1 microsecond ago or 10 hours ago, is linked into **one giant singly-linked list** called **`allgc`**:

```text
Standard Lua 5.3.4 Heap (all objects mixed in a single 'allgc' list):
allgc ──► [TempTable1] ──► [TempTable2] ──► [ConfigA] ──► [ConfigB] ──► ... (1,000,000 resident objects)
```

To figure out which objects are still in use and which ones are garbage, Lua uses **Three-Color Incremental Mark-and-Sweep**. Imagine every object wears a tag with one of three colors:
- ⚪ **White**: *"Unvisited / candidate for deletion"*. Every newly created object starts out White. If an object is still White at the end of the marking phase, nobody can reach it anymore, so it gets freed during the sweep phase.
- 🔘 **Gray**: *"I am alive, but the objects I point to (e.g., fields inside this table) haven't been checked yet"*. Gray objects are linked into a to-do queue (`gray` list).
- ⚫ **Black**: *"I am alive, and all objects I directly point to have been checked"*.

#### 2. A Concrete Production Scenario
Imagine a game server or backend service:
- At startup, it loads **1,000,000 configuration entries and script functions** (~**150 MB** of memory) that stay alive forever.
- Every incoming request creates **1,000 temporary tables** that become garbage as soon as the request finishes.

Now watch what standard Lua 5.3.4 does on **every single GC cycle**:

1. **Mark Phase (`propagatemark`)**:
   Starting from roots (`_G`, registry, stack), Lua traces every reachable object. Because the 1,000,000 config objects are reachable from `_G`, Lua must **walk through all 1,000,000 permanent objects** and repaint them ⚪White → 🔘Gray → ⚫Black!
2. **Sweep Phase (`sweeplist`)**:
   Once marking finishes, Lua must walk through the entire **1,001,000-node `allgc` linked list** from head to tail:
   - For the **1,000 ⚪White temporary objects** → call `free()` (the only useful work!).
   - For the **1,000,000 ⚫Black permanent objects** → **flip their color back from ⚫Black to ⚪White**, just so the next GC cycle can mark and sweep them all over again!

> 💥 **The Bottleneck**: To reclaim just **1,000** temporary objects, standard Lua 5.3.4 repeatedly traverses **1,000,000** immortal objects twice per cycle (1M in `propagatemark` + 1M in `sweeplist`). In CPU profiles, `propagatemark` and `sweeplist` consume **30%+ of total CPU time** and cause multi-millisecond latency spikes!

---

### Step 2: The Core Idea — Separate "Permanent Residents" from "Temporary Visitors" (`oldgc` Isolation)

If those 1,000,000 resident objects stay alive across cycles, why check them every round?
`lua53plus` splits the heap into **two physical rooms (linked lists)**: a **Young Room (`allgc`)** and an **Old Room (`oldgc`)**:

```text
==================== Standard Lua 5.3.4 (One Mixed List) ====================
allgc: [Temp1] -> [Temp2] -> [Resident1] -> [Resident2] -> ... -> [Resident 1,000,000]
       (Every GC cycle marks all 1,001,000 objects AND sweeps all 1,001,000 objects!)

==================== lua53plus (Young vs. Old Physical Isolation) ====================
Young Gen (allgc): [NewTemp1 (⚪White)] -> [NewTemp2 (⚪White)]          (~1,000 objects: scanned!)
Old Gen (oldgc):   [Resident1 (⚫Black+OLD)] -> [Resident2 (⚫Black+OLD)] (1,000,000 objects: skipped!)
```

Here is how it works in 3 simple steps:

1. **New objects always enter the Young Room (`allgc`)**:
   Every newly allocated object starts out ⚪White at the head of `allgc`.
2. **Survivors during Sweep get promoted to the Old Room (`entersweep` + `sweeptobeswept`)**:
   When an incremental GC cycle enters the sweep phase, `lua53plus` detaches `allgc` into a temporary sweep list (`tobeswept`) and resets `allgc = NULL` for new allocations.
   As `sweeptobeswept` walks `tobeswept`:
   - If an object is ⚪**White** (died young) → `freeobj()` frees it immediately.
   - If an object is ⚫**Black** (survived the cycle) → **do NOT flip it back to White!** Instead, stamp it with **`BLACKBIT | OLDBIT`** and move it into **`g->oldgc` (the Old Room)**!
3. **Routine Minor GC cycles skip the Old Room completely (Zero Cost!)**:
   - **How `propagatemark` skips `oldgc`**:
     In Lua's marker, `markobject` only marks ⚪White objects (`if (iswhite(o))`). Because every object in `oldgc` is kept ⚫**Black** (`BLACKBIT | OLDBIT`), whenever the marker encounters a pointer to an old object, `iswhite(o)` is `false` — **it returns immediately without pushing the old object onto the gray list or scanning its children!**
   - **How `sweeptobeswept` skips `oldgc`**:
     The sweeper only walks `tobeswept` (the ~1,000 young objects). **It never touches `g->oldgc` at all!** Sweep complexity drops from `O(Total Heap)` to `O(Young Nursery)`.

---

### Step 3: The Hard Part — What If an "Old Object" Points to a "New Object"? (Write Barriers)

Splitting into two rooms sounds simple, but there is one classic trap we must solve:

> ❓ **The Trap**: Suppose `OldTable` lives in `oldgc` (wearing a ⚫Black badge, so GC skips it).
> Now your Lua script runs:
> ```lua
> OldTable.player = { name = "Newbie" }  -- Stores a brand-new ⚪White table inside a ⚫Black old table!
> ```
> If no other variable points to `{ name = "Newbie" }`, what happens during the next Minor GC? Because `OldTable` is ⚫Black, the marker skips `OldTable` and never looks inside its fields! As a result, `{ name = "Newbie" }` remains ⚪White and gets mistakenly freed by the sweeper while `OldTable.player` still points to it!

How does `lua53plus` prevent this? With **Write Barriers — a "Modified Old Objects Logbook"**:

```text
         [Old Object: OldTable (⚫Black+OLD)]
                       │
      Executes: OldTable.player = NewObj(⚪White)
                       ▼
         Triggers Write Barrier (luaC_barrierback_)
                       │
      ┌────────────────┴────────────────┐
      ▼                                 ▼
1. Turn OldTable 🔘Gray            2. Link onto 'grayagain' logbook
   and set TOUCHEDBIT                 grayagain ──► [OldTable]
```

Whenever Lua mutates a ⚫Black object to reference a ⚪White object, a lightweight write barrier fires:

- **Case A: Mutating a container like a Table or Closure (`luaC_barrierback_` / `luaC_barrier_`)**:
  `lua53plus` turns `OldTable` from ⚫Black back to 🔘Gray, sets **`TOUCHEDBIT`** on it, and links it onto **`g->grayagain`** (our "Modified Logbook").
  - Modified old tables stay 🔘Gray in `g->grayagain` throughout the main `GCSpropagate` phase so repeated mutations to hot old tables incur **zero barrier overhead** and never dirty the same table twice.
  - Threads and weak tables are linked into a dedicated `g->grayatomic` list so `g->grayagain` holds only barrier-dirtied strong containers. Once `g->gray` finishes its normal root/young traversal, `GCSpropagate` swaps `g->grayagain` into `g->gray` (`g->drainedgray`) in `O(1)` time and drains all modified tables **incrementally across GC steps** before entering `GCSatomic` (without re-traversing threads or weak tables), while `luaC_step` isolates `GCSatomic` into its own step so atomic traversal never stacks onto propagation or sweep steps.
- **Case B: Forward barriers outside the mark phase (Intrusive `remuv` / `remudata` lists)**:
  For closed upvalue (`UpVal`) or userdata (`Udata`) mutations outside the mark phase, `lua53plus` links the modified `UpVal` or `Udata` into unbounded `O(1)` intrusive remembered lists (`g->remuv` and `g->remudata`). Repeated writes to the same upvalue or userdata are `O(1)` deduplicated no-ops, never overflow any fixed buffer, and only mark the latest live value at `restartcollection`.
- **Case C: Weak Tables and Coroutines (`oldweak` list)**:
  Weak tables (`__mode = "k"` / `"v"`) and live coroutines (`lua_State` threads whose stacks change without write barriers) cannot be left ⚫Black. When they survive a cycle, `sweeptobeswept` links them onto a dedicated short list **`g->oldweak`** so `restartcollection` re-traverses them on every Minor GC.

---

### Step 4: How Do Dead Old Objects Get Reclaimed? (100% Incremental Major GC vs. Lua 5.4's Stop-The-World `fullgen`)

> ❓ **Second Question**: What if an object survives one cycle, gets promoted to `oldgc` (e.g., a player session that lasted 10 minutes), and *then* disconnects and dies? If `oldgc` is skipped forever, wouldn't dead old objects leak memory?

Yes! That is why every generational collector periodically runs a **Major GC (Full-Heap Cleaning)** to reclaim old objects that have died.

#### 1. When does `lua53plus` trigger a Major GC?
- When post-sweep live heap bytes grow by more than **20%** (`GCestimate > lastmajbytes * 1.20`) or pre-GC total bytes exceed **1.33x** of `lastmajbytes`;
- When the number of promoted old objects grows by more than **25%** since the last Major GC (`oldcount > lastmajcount * 1.25`), or after every **8 consecutive Minor GC cycles** (`minorcycles >= 8`) to guarantee dead old objects from temporary ramp-up peaks are promptly reclaimed;
- When the user explicitly calls `collectgarbage("collect")`, or when a weak-mode metatable (`__mode`) is dynamically attached to a non-white table (`needmajor = 1`).

#### 2. Why Lua 5.4's Generational GC (`KGC_GEN`) Still Spikes on Large Heaps
In Lua 5.4's generational mode (`lgc.c`: `fullgen`), when the collector decides to run a Major GC, it executes a **synchronous, non-incremental stop-the-world pass**—bleaching, marking, and sweeping the entire multi-hundred-megabyte heap in a single step, causing tens of milliseconds of pause latency!

#### 3. How `lua53plus` Makes Even Major GC 100% Incremental (`startbleach` + `bleachstep`)
In `lua53plus`, **even Major GC is 100% incremental step-by-step from start to finish!**

To start a Major GC, all 1,000,000 ⚫Black old objects in `oldgc` must first be "bleached" back to ⚪White and moved back into `allgc`. Even a simple `for` loop that walks 1,000,000 linked-list pointers in one shot to flip their color bits would cause a multi-millisecond CPU cache-miss spike!

Instead, `lua53plus` uses **`startbleach` + `bleachstep` incremental bleaching**:

```text
Incremental Bleaching Phase at the Start of Major GC (inbleach = 1):
Each GC singlestep pops at most GCSWEEPMAX (~a few dozen) objects from 'oldgc',
bleaches them to ⚪White, and prepends them to 'allgc' in O(1):

Step 1:  oldgc ──► [Old1]─►[Old2]─►...─►[Old100] ──► (999,900 remaining for subsequent steps)
                    └─── Bleached to ⚪White & O(1) prepended to allgc ───┘
Step 2:  Bleach next 100 objects...
...
Once oldgc is empty ──► Incremental Mark (GCSpropagate) ──► Incremental Sweep (GCSswpallgc)
```

Every phase of a Major GC is sliced into tiny microsecond steps:
1. **Incremental Bleaching (`bleachstep`)**: Each `singlestep` pops at most `GCSWEEPMAX` objects from the head of `g->oldgc` / `g->oldfinobj`, resets their mark bits to `luaC_white(g)`, and splices them onto `g->allgc` / `g->finobj` in `O(1)` time with hardware prefetching (`l_prefetch`).
2. **Incremental Marking (`GCSpropagate`)**: Marks a few dozen objects per step.
3. **Incremental Sweeping & Re-Promotion (`GCSswpallgc`)**: Sweeps `GCSWEEPMAX` objects per step—dead old objects are freed, and surviving old objects are promoted back into `g->oldgc` with `BLACKBIT | OLDBIT`.

---

### Step 5: Accelerating the #2 CPU Hotspot — Short-String Table Lookups (`luaH_fastgetshortstr`)

Once GC overhead is eliminated, CPU profiling shows that the next largest hotspot in Lua is **string-keyed table lookups** (`t.field`, `t["key"]`, `obj:method()`). `lua53plus` speeds this up in three ways:

1. **Header-Inlined Fast-Path (`luaH_fastgetshortstr`, `luaH_fastget`)**:
   Inlines short-string hash lookup and integer array-bounds checks directly into `lvm.c`, `lapi.c`, and `ltm.c`, eliminating cross-translation-unit call overhead in `luaV_execute`.
2. **Pointer-First Interned Short-String Comparison**:
   In Lua 5.3, all short strings (<= 40 bytes, `LUA_TSHRSTR`) are uniquely interned in the global string table—two equal short strings always have the exact same `TString*` pointer.
   Standard Lua checks the node's type tag `ttisshrstring(k)` first and compares the pointer second. `lua53plus` **compares the 64-bit pointer `val_(k).gc == obj2gco(key)` first** and verifies `ttisshrstring(k)` second, rejecting non-matching keys in a single register comparison with minimal branch mispredictions.
3. **Cache-Line Buddy Probing (`getfreepos`)**:
   When a hash collision occurs in `luaH_newkey`, standard Lua scans backward from the end of the table (`lastfree`), scattering colliding nodes across distant memory addresses. `lua53plus` first probes buddy slots (`idx ^ 1`, `idx ^ 2`, `idx ^ 3`) within the same **64B / 128B CPU L1 cache line**, keeping collision chains cache-local.

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

### Running Tests & Benchmarks

```bash
# Run randomized cross-generation GC & write-barrier fuzz test suite
./src/lua tests/test_gc_fuzz.lua

# Run benchmarks
./src/lua bench/bench_gc_largeheap.lua
./src/lua bench/bench_table_lookup.lua
./src/lua bench/bench_mixed_workload.lua
```

---

## License

Same as PUC-Lua 5.3.4 — [MIT License](http://www.lua.org/license.html).
