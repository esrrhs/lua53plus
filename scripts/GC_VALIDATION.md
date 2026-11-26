# GC 不变式、OOM 与性能回归验证

本轮只新增测试/调试适配；不改变 release GC，也不引入 release 扫链开销。
生成内容在忽略的 `validation-results/`，请保留想比较的 `metrics.json`。
现有 Ubuntu 64/32、macOS、Linux/macOS ASan+UBSan 矩阵不删减。

## 1. 官方 T.checkmemory 适配

```sh
./scripts/fetch_testes.sh
./scripts/build_with_ltests.sh linux   # macOS: macosx
make test-udata
FUZZ_REQUIRE_UDATA=1 FUZZ_OPS=5000 ./src/lua tests/test_gc_fuzz.lua
./scripts/run_gc_validation.sh ltests
make test-testes
```

`fetch_testes.sh` 仍下载/校验官方归档，再调用 `patch_ltests.py`，补丁锚点不匹配即失败。
不要对已打补丁的 ltests 再运行 Python 补丁；重新 fetch 即可。
只在 T 构建包含这些检查，普通发行版无此代码。CI 的完整套件步骤实际联跑 T fuzz，
且强制加载 userdata helper，不再只在普通 assert 构建 fuzz。

### 为什么不是“所有 old → young 都可以”

根据 `src/lgc.c` 的 barrier / restartcollection / singlestep / checkfinalizer：

* 标记期必须保持黑→白禁令，没有 old 或 TOUCHEDBIT 总豁免。
* 非标记期 forward barrier 对 userdata 保持黑色，但必须实际在 `remudata` 且有
  TOUCHEDBIT。Table/closure/Proto 应变灰并在 grayagain，而非黑色特批。
* closed UpVal 不着色：仅当**这一条 UpVal** 的 `upisinrem`（`remnext != uv` 自指哨兵）与 `remuv` 成员身份一致时，
  非标记期允许其值白色；不放宽整个 closure 的 Proto 或其他 UpVal 引用。
* sweep 按官方允许颜色不变式暂时失效。sweep 后 mainthread 被单独漂白；存活
  thread / weak table 留白并在 oldweak；因此非标记期允许指向这些**确定的目标**。
* `checkfinalizer` 在非标记/非漂白期将老对象漂白挂入 `finobj`（保证逆注册析构顺序）并强制 `needmajor`。仅非标记期
  old 引用允许这个时间窗口：进入下一次标记前，pause 分支必先 bleach/merge 全部 old。
* `inbleach && GCSpause` 时 barrier 故意不维护颜色，尚未漂白的 old 可指向白对象；
  bleach 完成后才 restartcollection，不能将这个例外扩大到标记期。
* pause 中白对象必须非 old；old 非白必须黑色，或有 TOUCHEDBIT 且在 grayagain。
  bleach 清空 remembered 链但未处理的 old 暂留原颜色，故仅在 bleach 允许 touched 灰 old 脱链。

故意移除 userdata barrier、清除 mandatory-major、制造无归属 pause 灰对象、破坏
listprev、让两个 primary list 重叠、破坏 remuv `upisinrem`，均须被检查以 **SIGABRT** 拒绝；普通退出/加载失败
不是负向测试通过。故障仅由测试程序参数在一次性进程内制造，不修改生产源码。

## 2. 链表与定向回归

T.checkmemory 检查 8 个 primary list（allgc / finobj / tobefnz / fixedgc / oldgc /
oldfinobj / tobeswept / tobesweptfin）无环且两两不相交（用链尾判断，总体线性）。
oldgc 上 Table/Udata 的 listprev 必须准确等于前驱；其他链上必须 NULL。
remuv 无环、成员必须 closed 且 `upisinrem`；引用检查反向验证 `upisinrem` 对应实际成员；`oldweak` 节点数精确等于 `oldweakcount`。
refcount=0 的 remuv 合法：由 clearremlists 延迟释放。remudata 校验无环、类型、
TOUCHEDBIT；正在 promotion sweep 的 userdata 可能尚非 old，不错误排除这个窗口。

`tests/gc_validate.c` 使用真实的 collector 转换：old userdata 晚加 __gc 摘链、
年轻 metatable 的 mandatory-major、增量 bleach、半漂白时 fullgc 合并、完成漂白、
finalizer 复活及再次回收。只用 needmajor（生产相同触发器）要求 major，不伪造 GC 状态。
每阶段调用 T.checkmemory；普通构建也执行语义/allocator 检查。

## 3. failing allocator

```sh
# 当前必须是普通 liblua.a；带 T 的库改传 ltests，ABI 必须一致。
./scripts/run_gc_validation.sh release
# 和已有 sanitizer 构建保持完全相同 flags：
EXTRA_CFLAGS='-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer' \
EXTRA_LDFLAGS='-fsanitize=address,undefined' ./scripts/run_gc_validation.sh release
./scripts/run_sanitizer_tests.sh linux
```

每个 fail point 重新建状态。在 old pause、propagate、young sweep、partial bleach、
复活后五种状态，分别遍历前 48 次增长分配：persistent（连 emergency retry 也失败）
及 one-shot（仅首次失败）。共 480 个独立状态，外加 2 个 __gc 内复活之后的精确 OOM。
链拼接本身不分配；测试从拼接/漂白中途发起分配，令 emergency fullgc 合并并验证恢复。

persistent 必须返回 LUA_ERRMEM；one-shot 允许 emergency GC 后成功，不能把成功误报成
“没注入”——每个案例都记录真实失败次数。恢复 allocator 后继续执行 Lua、完整回收、
close 后 allocator live bytes 和 blocks 必须归零。__gc 的内存错误仍为 LUA_ERRMEM；
Lua 5.3 的 GCTM 仅包装 LUA_ERRRUN 为 LUA_ERRGCMM。
工作负载使用 VM table/userdata 分配；不把 luaL_Buffer 的 LUA_ERRRUN 当成 LUA_ERRMEM。
这不是穷举所有 allocator call site，也不验证外部 C 扩展自己的分配器。

## 4. 可复现性能入口

```sh
python3 scripts/bench_gc_regression.py
GC_BENCH_REPEATS=7 GC_BENCH_SAMPLES=20000 \
GC_BENCH_DIR=/workspace/my-gc-metrics python3 scripts/bench_gc_regression.py
python3 tests/test_gc_bench_limits.py
```

官方 baseline 来自 https://www.lua.org/ftp/lua-5.3.4.tar.gz ，SHA256 与官网 ftp 列表核对：
`f681aa518233bc407e23acf0f5887c884f17436f000d453b2491a9f11a52400c`。
两个库在隔离目录构建，默认同一 `cc`，同一
`-O2 -std=gnu99 -DLUA_USE_POSIX -DLUA_USE_DLOPEN`，无 T、assert/sanitizer；
C helper 也用同样 flags。可覆盖 `CC`、`GC_BENCH_CFLAGS`、`GC_BENCH_LDFLAGS`。
不清理/重建工作区 src，因此不会把 T 库误当 release baseline。

口径：固定 seed=101、20000 常驻 table，每 tick 建 64 对 parent/child 并写入常驻对象。
每进程预热 500 tick + fullgc；额外丢弃两种引擎各一次完整进程运行；至少 3（默认 5）次
独立重复，交替 baseline/plus 先后顺序，保留全部原始数据，摘要取各指标的重复中位数。
Linux CLOCK_MONOTONIC / macOS mach_absolute_time 计 wall time，单位微秒。

* 自动 GC 停止，但每 tick 显式 `lua_gc(L,LUA_GCSTEP,0)`；该 API 临时打开 gcrunning，
  不会关闭 lua53plus promotion。**p99/max 是显式单步调用耗时，不是所有自动 GC 停顿**。
* allocation batch 单独统计 p99/max，不混充 GC；同样 API 预算不代表两种 collector 完成
  等量 GC 工作。故单列结束时两次 fullgc 的 drain 时间、包含 drain 的总时间和回收后 live。
  单步暂停下降而内存/尾部 drain 上升不能宣称是无代价的性能提升。
* allocator 精确累计 Lua 请求 live/peak 字节（不含 malloc header/碎片）。RSS 是计时结束
  时进程驻留；ru_maxrss 是本进程全生命周期高水位（含预热、二进制和 libc），两者不要混用。
* `sizeof(Table/Udata)` 对照原版是整体布局差异；另有**仅移除 listprev 声明**的 header-only
  编译探针，含 padding，隔离量化这两个字段的大小税，不编译/执行改坏的 GC。

### 门槛：实现了，但默认只报告

`GC_BENCH_LIMITS=/path/calibrated.json` 启用失败门禁；格式为
`{"gc_p99_us":{"ratio":R,"slack":S},"lua_peak_bytes":{"ratio":M,"slack":B}}`
（R/M 必须 >=1；S 为微秒、B 为字节；所有值需要替换为 runner 校准出的实际预算）。
判据 `plus > baseline * ratio + slack`，使共享 runner 可同时给相对和绝对宽松量。
可不重跑基准而复核门槛：

```sh
python3 scripts/check_gc_metrics.py validation-results/benchmark/metrics.json /path/calibrated.json
```

**不凭一台共享机的几次样本捏造通用默认门槛。** 目前 CI 上传 report-only metrics；要变成
可靠的默认阻塞门禁，还需在目标 runner 收集多批历史分布、选噪声预算并提交配置。
性能数字是某个 workload/主机的观测，不能泛化为所有应用，也不能拿单次 max 判定回归。
