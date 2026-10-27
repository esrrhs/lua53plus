# lua53plus

[![CI](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml/badge.svg)](https://github.com/esrrhs/lua53plus/actions/workflows/ci.yml)

[English Documentation (README.md)](./README.md)

**`lua53plus`** 是基于官方 **PUC-Lua 5.3.4** 深度优化的高性能纯单线程 C 增强版本，保持 **100% C API / ABI 与字节码无缝兼容**。

本项目专为在 C/C++ 服务端进程中内嵌 Lua 5.3 VM、且存在**大体量常驻内存**（数百 MB 的长生命周期配置表、脚本函数原型、闭包与常驻状态）并持续处理高频请求（不断分配短生命周期临时表、密集执行短字符串 key 表查找）的生产场景设计。

---

## 为什么需要 `lua53plus`？

在标准 PUC-Lua 5.3.4 中，增量式标记-清除垃圾回收器（`lgc.c`）没有分代隔离机制（Lua 5.2 曾尝试的实验性分代 GC 在 Lua 5.3.0 中被移除）。当 Lua VM 持有较大的常驻内存堆（例如 50 MB ～ 500 MB 的配置与常驻对象）时，会出现显著的性能瓶颈：

1. **`propagatemark` 与 `sweeplist` 占用 ~30% 以上的 CPU：**
   每一次增量 GC 周期，无论实际只产生了几 MB 的请求临时垃圾，GC 都必须在标记阶段（`propagatemark` / `traversestrongtable`）和清除阶段（`sweeplist`）反复全量扫描 `allgc` 链表中数以百万计的常驻存活对象。
2. **毫秒级 GC 停顿毛刺（Tail Latency Spikes）：**
   在原子阶段（`atomic`）或调低 GC 触发阈值（如 `setpause <= 110`）以控制内存增长时，全堆扫描会导致严重的 CPU 缓存抖动（Cache Thrashing），引发数毫秒乃至数十毫秒的单步停顿。
3. **`luaH_getshortstr` 与 `luaH_get` 查找开销：**
   标准 PUC-Lua 5.3.4 在每次虚拟机表访问（`OP_GETTABLE`、`OP_GETTABUP`、`OP_SELF`、`luaV_finishget`、`luaT_gettm`）时均需经由非内联的 `luaH_get` / `luaH_getstr` / `luaH_getshortstr` 函数调用，且先检查类型 tag 再比较指针，在高频短字符串字段访问下产生大量函数调用与分支预测开销。

`lua53plus` 在**不引入任何外部依赖、完全不改变公开结构体布局、C ABI 及预编译字节码兼容性**的前提下，从 GC 架构与表查找热路径两方面彻底解决了上述瓶颈。

---

## 核心优化详解

### 1. 老年代 GC 链表隔离（`oldgc`）与写屏障机制（`src/lgc.c`, `src/lgc.h`, `src/lstate.h`）
- **年轻代与老年代物理链表隔离（`allgc` vs. `oldgc`）：**
  在增量 GC 进入清除阶段（`entersweep`）时，`lua53plus` 将当前 `allgc` 链表整体剥离至待清除链表 `tobeswept`（`finobj` 剥离至 `tobesweptfin`），并将 `allgc` 置空，使后续新分配的对象全部进入干净的年轻代链表。
- **`sweeptobeswept` 自动晋升：**
  在增量清除过程中，`tobeswept` 中不可达的年轻代临时对象被立即释放；存活下来的对象则自动晋升（Promote）至 `g->oldgc`（或 `g->oldfinobj`），并保持 `BLACKBIT | OLDBIT` 标记位。
- **Minor GC 周期零开销跳过常驻对象：**
  由于 `g->oldgc` 中的老年代常驻对象在 Minor GC 周期中始终保持黑色（`BLACKBIT | OLDBIT`）且不在 `g->allgc` 链表中：
  - **标记阶段（`propagatemark`）** 遇到指向老年代对象的引用时因 `!iswhite(o)` 直接跳过，无需递归遍历老年代对象图；
  - **清除阶段（`sweeptobeswept`）** 仅扫描年轻代 `tobeswept` 链表，完全不触碰 `g->oldgc`，将清除复杂度从 $O(\text{全堆对象数})$ 降至 $O(\text{年轻代对象数})$。
- **精确写屏障（Write Barriers）与弱表/协程追踪：**
  - 当老年代黑色对象被写入指向年轻代白色对象的引用时（`luaC_barrier_` / `luaC_barrierback_`），写屏障将老年代容器置为 `TOUCHEDBIT` 并挂入 `g->grayagain`（若在非标记阶段触发 userdata/upvalue 前向屏障，则记录在固定容量的记忆集缓冲区 `g->rembuf` 中）。
  - 下一次 Minor GC 启动（`restartcollection`）时，直接从 `g->grayagain`、`g->oldweak`（存活协程与弱表）及 `g->rembuf` 初始化根灰色集合，仅重新扫描被修改过的老年代容器。
  - 当老年代晋升对象数量相比上次 Major GC 增长超过 50%（`oldcount > lastmajcount * 1.5`）、显式调用 `collectgarbage("collect")` 或老年代对象动态设置 `__mode` 弱表元表时，自动执行 `mergeoldgen` 触发全量 Major GC，确保长周期下无内存泄漏。

### 2. 内联 `luaH_fastgetshortstr` 与缓存行友好的哈希冲突链（`src/ltable.h`, `src/ltable.c`, `src/lvm.c`, `src/ltm.c`）
- **内联快速路径（`luaH_fastgetshortstr` / `luaH_fastgetstr` / `luaH_fastget`）：**
  将短字符串哈希桶查找与整数数组下标边界检查内联至 `ltable.h`，直接在 `lvm.c`、`lapi.c` 和 `ltm.c` 的热路径中展开。
- **优先比较短字符串唯一指针（Pointer-First Comparison）：**
  利用 Lua 5.3 短字符串（`LUA_TSHRSTR`）全局唯一内联（Interned）的特性，优先执行 `val_(k).gc == obj2gco(key)` 64 位寄存器比较，再验证 `ttisshrstring(k)`，在单次比较中即可完成主桶命中判定或快速排除不匹配节点，显著降低分支预测失败率。
- **同缓存行伙伴槽位探测（Cache-Line Buddy Probing）：**
  在 `luaH_newkey` 处理哈希冲突寻找空闲节点（`getfreepos`）时，优先探测同一 64B/128B CPU 缓存行内的伙伴槽位（`idx ^ 1`、`idx ^ 2`、`idx ^ 3`），使冲突链尽可能落在同一 L1/L2 缓存行内。
- **表扩容直接插入（`luaH_resize`）：**
  在表扩容重哈希时，直接将旧节点写入新数组槽位或调用 `luaH_newkey`，省去原版通过 `luaH_set` 带来的冗余查找。

---

## 基准测试对比（PUC-Lua 5.3.4 vs `lua53plus`）

测试脚本位于 [`bench/`](./bench/) 目录，在 Linux x86_64（`gcc -O2`）下对比原版 **PUC-Lua 5.3.4**（`a4f7d29`）与 **`lua53plus`**：

### 1. 大常驻堆吞吐量与 GC 停顿延迟（`bench/bench_gc_largeheap.lua`）

模拟服务端常驻大量长生命周期配置表/闭包，同时高频分配请求临时表（`req`、`payload`、`meta`）并读取常驻数据的场景：

| 测试指标 | PUC-Lua 5.3.4 | `lua53plus` | 提升幅度 |
| :--- | :---: | :---: | :---: |
| **45 MB 常驻堆 — 标准参数 (`pause=150`)** | 0.4430 s (1,128K req/s) | **0.3182 s (1,571K req/s)** | **吞吐量提升 +39.3%** |
| **45 MB 常驻堆 — 低延迟参数 (`pause=110`)** | 0.4260 s (1,174K req/s) | **0.3109 s (1,608K req/s)** | **吞吐量提升 +37.0%** |
| **171 MB 常驻堆 — 低延迟参数 (`pause=110`, 200万请求)** | 3.6575 s (547K req/s) | **1.5203 s (1,316K req/s)** | **吞吐量 2.41 倍（耗时降低 58.4%）** |
| **GC 单步停顿延迟 — 平均值 (`collectgarbage("step", 64)`)** | 19.7 µs | **2.6 µs** | **平均停顿降低 7.6 倍** |
| **GC 单步停顿延迟 — P99** | 150.0 µs | **65.0 µs** | **P99 停顿降低 2.3 倍** |
| **GC 单步停顿延迟 — 最大毛刺 (45 MB / 171 MB 堆)** | 3.85 ms / 28.73 ms | **0.54 ms / 2.14 ms** | **最大毛刺降低 7.1 ～ 13.4 倍** |

### 2. CPU 热点占比剖析（130 MB 常驻堆下的 `perf record` 采样）

| 函数 / 模块 | PUC-Lua 5.3.4 (% CPU) | `lua53plus` (% CPU) | 说明 |
| :--- | :---: | :---: | :--- |
| `sweeplist` / `sweeptobeswept` | **17.12%** | **1.51%** | 常驻对象隔离于 `oldgc`，仅清除年轻代临时对象 |
| `propagatemark` | **11.78%** | **< 1.10%** | 常驻对象保持 `BLACKBIT \| OLDBIT`，Minor GC 免扫描 |
| `luaH_get` / `luaH_getshortstr`（非内联调用） | **15.95%** | **< 0.50%** | 热路径全部内联至 `luaV_execute` |
| `luaV_execute`（有效字节码执行） | 5.59% | **38.44%** | CPU 算力从 GC 空转与查找开销回到业务字节码执行 |
| **200 万次请求总耗时与峰值内存** | **3.005 s（峰值 151.5 MB）** | **2.087 s（峰值 132.2 MB）** | **提速 1.44 倍，且峰值内存降低 19.3 MB** |

### 3. 短字符串表查找与综合业务负载（`bench/bench_table_lookup.lua`, `bench/bench_mixed_workload.lua`)

| 基准测试项 | PUC-Lua 5.3.4 | `lua53plus` | 性能提升 |
| :--- | :---: | :---: | :---: |
| **短字符串字段直接访问（8000 万次查找）** | 0.5728 s | **0.5051 s** | **+13.4%** |
| **大表短字符串冲突链查找（2048 键）** | 2.0797 s | **1.8050 s** | **+15.2%** |
| **OOP 方法调用与二级 `__index` 元表查找** | 0.3244 s | **0.2730 s** | **+18.8%** |
| **动态短字符串表构建与扩容（`luaH_resize`）** | 0.0189 s | **0.0175 s** | **+8.0%** |
| **综合端到端业务负载（`bench_mixed_workload.lua`）** | 0.0696 s | **0.0532 s** | **+30.8%** |

---

## 编译与无缝替换指南

### 编译 `lua53plus`

```bash
# Linux 平台
make linux

# macOS 平台
make macosx

# 清理构建产物
make clean
```

构建完成后在 `src/` 下生成：
- `src/liblua.a`：可直接静态链接至 C/C++ 宿主程序的静态库
- `src/lua`：Lua 5.3.4 独立解释器
- `src/luac`：Lua 5.3.4 字节码编译器

### 在现有 C/C++ 项目中直接替换

`lua53plus` 与标准 PUC-Lua 5.3.4 保持 **100% 头文件、C ABI、编译参数及二进制字节码兼容**：

1. 将项目中原有的 `lua-5.3.4/src` 源码目录（或编译出的 `liblua.a`）替换为 `lua53plus/src`。
2. 重新编译即可 —— 无需修改任何 C/C++ 宿主代码、链接参数或 Lua 脚本。

### 运行基准测试

```bash
./src/lua bench/bench_gc_largeheap.lua
./src/lua bench/bench_table_lookup.lua
./src/lua bench/bench_mixed_workload.lua
```

---

## 开源协议

与 PUC-Lua 5.3.4 相同 —— [MIT License](http://www.lua.org/license.html)。
