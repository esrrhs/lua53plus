# 平台与 sanitizer 测试

本文说明 CI 矩阵、本地复现命令，以及「本机实际跑过」和「仅待 CI」的界限。

官方 PUC-Lua 5.3.4 testes 细节见 `scripts/TESTES.md`。英文对照：`scripts/TESTING.md`。

## CI 矩阵

配置在 `.github/workflows/ci.yml`。原有覆盖均保留；macOS 现跑完整官方 testes，
Linux ASan 现跑完整官方 testes 并打开 LeakSanitizer。新增两个 job：32 位 Linux、
macOS ASan+UBSan。

| Job | Runner | 构建 | e2e | GC fuzz（`FUZZ_REQUIRE_UDATA=1`） | 官方 testes basic | 官方完整 testes（`ltests`，`_port=true`） | Sanitizers |
|-----|--------|------|-----|----------------------------------|-------------------|------------------------------------------|------------|
| `ubuntu-linux` | `ubuntu-latest` | `make linux`（APICHECK 后再 release） | 是（两轮） | 是，5000 ops（两轮） | 是（两轮） | 是 | 无 |
| `macos-macosx` | `macos-latest` | `make macosx`（APICHECK 后再 release） | 是（两轮） | 是，5000 ops（两轮） | 是（两轮） | 是 | 无 |
| `ubuntu-linux32` | `ubuntu-latest` | `make linux` + `-m32`（APICHECK 后再 release） | 是（两轮） | 是，5000 ops（两轮） | 是（两轮） | 是 | 无 |
| `asan-ubuntu` | `ubuntu-latest` | ASan+UBSan，`-O1 -g` | 是 | 是，6000 ops | 是 | 是 | ASan+UBSan+LSan（`detect_leaks=1`） |
| `asan-macos` | `macos-latest` | ASan+UBSan，`-O1 -g` | 是 | 是，6000 ops | 是 | 是 | ASan+UBSan；关闭 LSan（`detect_leaks=0`） |

所有 sanitizer job 都设置 `halt_on_error=1` 与
`UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`。发现的问题会让 job 失败。
不要设置 `exitcode=0`。

`ubuntu-linux` / `macos-macosx` / `ubuntu-linux32` 在 release 重建后仍会跑原有基准。

### 为何额外平台选 32 位 Linux 而不是 Windows MinGW

官方 `Makefile` 的 Unix `linux` 目标可以直接加 `-m32`，用同一套测试覆盖 32 位
指针、对齐以及 GC / C API 里的 `LUA_INTEGER` / `size_t` 宽度。Windows 虽有
`mingw` 目标，但 `t_udata` 和官方 `testes/libs` 需要单独的 `.exe` / `.dll` 接线，
且本机没有 MinGW 或 Wine，无法本地验证。

32 位 ASan 暂未进矩阵（本机无法运行，见下）。

### macOS sanitizer / testes 说明

- Apple Clang 支持 `-fsanitize=address,undefined`。
- Darwin 上 LSan 不可用，因此 `asan-macos` 使用 `detect_leaks=0`。
- 完整官方 testes 需要给 `testes/libs/*.so` 加上 `-undefined dynamic_lookup`。
  Makefile 使用 `override`，即便命令行设置了 `TEST_UDATA_LDFLAGS` 或
  `TESTES_LIBS_CFLAGS` 也会保留该标志（否则会冲掉它，导致 `t_udata.so` 链接失败）。
- `scripts/build_with_ltests.sh macosx` 用 `cc` 编译 `ltests`。

## 本地命令

### 默认（无 sanitizer）

```bash
make linux          # 或：make macosx
make test-udata
./src/lua tests/e2e/run_all.lua
FUZZ_REQUIRE_UDATA=1 FUZZ_OPS=5000 ./src/lua tests/test_gc_fuzz.lua
./scripts/fetch_testes.sh
make test-testes-basic
./scripts/build_with_ltests.sh linux    # 或 macosx
make test-testes
```

### 32 位 Linux

需要 32 位 libc 和 `gcc -m32`（Ubuntu：`gcc-multilib libc6-dev-i386`）。

```bash
make linux MYCFLAGS=-m32 MYLDFLAGS=-m32
make test-udata TEST_UDATA_CFLAGS='-std=gnu99 -O2 -fPIC -Isrc -m32'
./src/lua tests/e2e/run_all.lua
FUZZ_REQUIRE_UDATA=1 ./src/lua tests/test_gc_fuzz.lua
./scripts/fetch_testes.sh
make test-testes-basic
EXTRA_CFLAGS=-m32 EXTRA_LDFLAGS=-m32 ./scripts/build_with_ltests.sh linux
make test-testes TESTES_LIBS_CFLAGS='-Wall -std=gnu99 -O2 -I../../src -fPIC -shared -m32'
```

### ASan + UBSan（Linux 上再加 LSan）

`scripts/run_sanitizer_tests.sh` 使用 `-fsanitize=address,undefined` 构建，
并运行 e2e、强制加载 `t_udata` 的 GC fuzz、官方 basic，然后（默认）用 ltests
重建并跑完整官方套件。

```bash
# Linux x86_64：ASan+UBSan+LSan，完整官方 testes
./scripts/run_sanitizer_tests.sh linux

# macOS：ASan+UBSan，脚本会自动关闭 LSan
./scripts/run_sanitizer_tests.sh macosx

# 可选环境变量：BITS=32 DETECT_LEAKS=0|1 RUN_FULL_TESTES=0|1 FUZZ_OPS=6000
#                FETCH_TESTES=1 EXTRA_CFLAGS EXTRA_LDFLAGS
```

Sanitizer 选项基线（脚本也会设置）：

- `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:detect_stack_use_after_return=1`
  （macOS 为 `detect_leaks=0`）
- `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`

## 本机实际跑过 vs 仅待 CI

日期：2026-11-10，下列时间为 Asia/Shanghai（UTC+8）。主机：Linux x86_64，
gcc 14.2.0，仓库基线 `9953963` 加上本次未提交的平台测试改动。
日志：`/workspace/lua53plus-platform-logs/`。

| 套件 | 本机跑过？ | 结果 |
|------|------------|------|
| Linux x86_64 ASan+UBSan+LSan e2e（107 例） | 是 | 通过（`02-asan-e2e-lsan.log`，以及 `05-…` 复跑） |
| Linux x86_64 ASan+UBSan+LSan GC fuzz，6000 ops，强制 `t_udata.so`，10 个 seed | 是 | 通过（`03-asan-fuzz-lsan.log`，以及 `05-…` 复跑） |
| Linux x86_64 ASan+UBSan+LSan 官方 testes basic（`_U=true`） | 是 | `final OK`（`04-…`，以及 `05-…` 复跑） |
| Linux x86_64 ASan+UBSan+LSan 官方完整 testes（`ltests`，`_port=true`） | 是 | `final OK`，墙钟约 68 秒（`05-run_sanitizer_tests-linux.log`，脚本退出码 0） |
| Linux 32 位任何构建或测试 | **否** | 阻塞：`gcc -m32` 找不到 `bits/libc-header-start.h`；本机 apt 中 `gcc-multilib` 的 Candidate 为 `(none)`，未安装。CI 在 Ubuntu 上预期会 `apt-get install gcc-multilib libc6-dev-i386`。 |
| macOS 构建、testes 或 ASan | **否** | 本机没有 macOS 主机。**仅能靠 CI。目前还没有远端 CI 结果**（改动尚未推送）。 |
| Windows / MinGW | **否** | 未加入矩阵；本机也没有 MinGW/Wine。 |

`05-run_sanitizer_tests-linux.log` 与 CI 中 `asan-ubuntu` 的路径相同
（`./scripts/run_sanitizer_tests.sh linux`，`DETECT_LEAKS=1`，`RUN_FULL_TESTES=1`）。
