# Platform and sanitizer testing

This document lists the CI matrix, how to run the same commands locally,
and what has actually been executed versus what is CI-only.

Official PUC-Lua 5.3.4 testes details: `scripts/TESTES.md`.

## CI matrix

Configured in `.github/workflows/ci.yml`. Existing coverage is kept; macOS
now also runs the complete official testes, Linux ASan also runs the
complete official testes with LeakSanitizer, and two jobs were added
(32-bit Linux, macOS ASan+UBSan).

| Job | Runner | Build | e2e | GC fuzz (`FUZZ_REQUIRE_UDATA=1`) | Official testes basic | Official testes complete (`ltests`, `_port=true`) | Sanitizers |
|-----|--------|-------|-----|----------------------------------|------------------------|---------------------------------------------------|------------|
| `ubuntu-linux` | `ubuntu-latest` | `make linux` (APICHECK, then release) | yes (both) | yes, 5000 ops (both) | yes (both) | yes | no |
| `macos-macosx` | `macos-latest` | `make macosx` (APICHECK, then release) | yes (both) | yes, 5000 ops (both) | yes (both) | yes | no |
| `ubuntu-linux32` | `ubuntu-latest` | `make linux` with `-m32` (APICHECK, then release) | yes (both) | yes, 5000 ops (both) | yes (both) | yes | no |
| `asan-ubuntu` | `ubuntu-latest` | ASan+UBSan, `-O1 -g` | yes | yes, 6000 ops | yes | yes | ASan+UBSan+LSan (`detect_leaks=1`) |
| `asan-macos` | `macos-latest` | ASan+UBSan, `-O1 -g` | yes | yes, 6000 ops | yes | yes | ASan+UBSan; LSan off (`detect_leaks=0`) |

All sanitizer jobs set `halt_on_error=1` and `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`.
Findings fail the job. Do not set `exitcode=0`.

`ubuntu-linux` / `macos-macosx` / `ubuntu-linux32` also run the existing
benchmarks after the release rebuild.

### Why 32-bit Linux (not Windows MinGW) as the extra platform

The official `Makefile` already has a Unix `linux` target that accepts
`-m32`. That exercises 32-bit pointers, alignment, and `LUA_INTEGER` /
`size_t` widths in the GC and C API with the same flags and tests as
64-bit Linux. Windows MinGW is a first-class `mingw` target, but it needs
`.exe` / `.dll` wiring for `t_udata` and official `testes/libs`, and it
could not be run on the Linux development machine (no MinGW or Wine).

32-bit ASan is not in the matrix yet (cannot be run on the current dev
machine; see below).

### macOS sanitizer / testes notes

- Apple Clang supports `-fsanitize=address,undefined`.
- LeakSanitizer is not usable on Darwin, so `detect_leaks=0` on `asan-macos`.
- Complete official testes need `testes/libs/*.so` linked with
  `-undefined dynamic_lookup` (the `test-testes` target adds this on Darwin).
- `scripts/build_with_ltests.sh macosx` compiles `ltests` with `cc`.

## Local commands

### Default (no sanitizers)

```bash
make linux          # or: make macosx
make test-udata
./src/lua tests/e2e/run_all.lua
FUZZ_REQUIRE_UDATA=1 FUZZ_OPS=5000 ./src/lua tests/test_gc_fuzz.lua
./scripts/fetch_testes.sh
make test-testes-basic
./scripts/build_with_ltests.sh linux    # or macosx
make test-testes
```

### 32-bit Linux

Requires a 32-bit libc and `gcc -m32` (on Ubuntu: `gcc-multilib libc6-dev-i386`).

```bash
make linux MYCFLAGS=-m32 MYLDFLAGS=-m32
make test-udata TEST_UDATA_CFLAGS='-std=gnu99 -O2 -fPIC -Isrc -m32' \
                TEST_UDATA_LDFLAGS='-shared -m32'
./src/lua tests/e2e/run_all.lua
FUZZ_REQUIRE_UDATA=1 ./src/lua tests/test_gc_fuzz.lua
./scripts/fetch_testes.sh
make test-testes-basic
EXTRA_CFLAGS=-m32 EXTRA_LDFLAGS=-m32 ./scripts/build_with_ltests.sh linux
make test-testes TESTES_LIBS_CFLAGS='-Wall -std=gnu99 -O2 -I../../src -fPIC -shared -m32'
```

### ASan + UBSan (+ LSan on Linux)

`scripts/run_sanitizer_tests.sh` builds with `-fsanitize=address,undefined`
and runs e2e, GC fuzz with `FUZZ_REQUIRE_UDATA=1`, official basic testes,
then (default) a ltests rebuild and the complete official suite.

```bash
# Linux x86_64: ASan+UBSan+LSan, complete official testes
./scripts/run_sanitizer_tests.sh linux

# macOS: ASan+UBSan, LSan disabled automatically
./scripts/run_sanitizer_tests.sh macosx

# Optional env: BITS=32 DETECT_LEAKS=0|1 RUN_FULL_TESTES=0|1 FUZZ_OPS=6000
#               FETCH_TESTES=1 EXTRA_CFLAGS EXTRA_LDFLAGS
```

Sanitizer option baseline (also set by the script):

- `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1:detect_stack_use_after_return=1`
  (`detect_leaks=0` on macOS)
- `UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1`

## What was actually run vs CI-only

Date: 2026-11-10, times below are Asia/Shanghai (UTC+8). Host: Linux x86_64,
gcc 14.2.0, repo at `9953963` plus this uncommitted platform-testing work.
Logs: `/workspace/lua53plus-platform-logs/`.

| Suite | Ran locally? | Result |
|-------|----------------|--------|
| Linux x86_64 ASan+UBSan+LSan e2e (107 cases) | yes | pass (`02-asan-e2e-lsan.log`, and again in `05-…`) |
| Linux x86_64 ASan+UBSan+LSan GC fuzz, 6000 ops, `t_udata.so` required, 10 seeds | yes | pass (`03-asan-fuzz-lsan.log`, and again in `05-…`) |
| Linux x86_64 ASan+UBSan+LSan official testes basic (`_U=true`) | yes | `final OK` (`04-…`, and again in `05-…`) |
| Linux x86_64 ASan+UBSan+LSan official testes complete (`ltests`, `_port=true`) | yes | `final OK`, ~68s wall (`05-run_sanitizer_tests-linux.log`, script exit 0) |
| Linux 32-bit any build or test | **no** | blocked: `gcc -m32` cannot find `bits/libc-header-start.h`; apt `gcc-multilib` candidate is `(none)` on this machine. Not installed (no usable package). CI on Ubuntu is expected to `apt-get install gcc-multilib libc6-dev-i386`. |
| macOS build, testes, or ASan | **no** | no macOS host here. **CI only. No remote CI result yet** (changes not pushed). |
| Windows / MinGW | **no** | not in the matrix; no MinGW/Wine on this machine. |

The `05-run_sanitizer_tests-linux.log` run is the same path CI `asan-ubuntu` uses
(`./scripts/run_sanitizer_tests.sh linux` with `DETECT_LEAKS=1` and
`RUN_FULL_TESTES=1`).
