#!/usr/bin/env bash
# Build lua53plus with GCC gcov instrumentation (--coverage), run both the
# standard release-ABI suites (e2e, GC fuzz with udata, 482-state OOM harness,
# basic official testes, luac) and the internal ltests suites (negative SIGABRT
# checks + full official PUC-Lua 5.3.4 testes), and emit a merged lcov report
# at validation-results/coverage.info scoped strictly to src/*.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FUZZ_OPS="${FUZZ_OPS:-5000}"
FETCH_TESTES="${FETCH_TESTES:-0}"
COV_CFLAGS="-O0 -g --coverage"
COV_LDFLAGS="--coverage"

cleanup_gcda() {
  rm -f src/*.gcda src/*.gcno \
        testes/ltests/*.gcda testes/ltests/*.gcno \
        validation-results/*.gcda validation-results/*.gcno
}

mkdir -p validation-results
rm -f validation-results/coverage*.info
cleanup_gcda

if [ ! -f testes/all.lua ] || [ "$FETCH_TESTES" = 1 ]; then
  echo "==== fetch official testes ===="
  ./scripts/fetch_testes.sh
fi

echo "==== coverage pass 1: standard build (e2e + fuzz + OOM + luac + basic testes) ===="
make clean
make linux MYCFLAGS="$COV_CFLAGS -DLUA_USE_APICHECK" MYLDFLAGS="$COV_LDFLAGS"
rm -f tests/t_udata.so
make test-udata TEST_UDATA_CFLAGS="-std=gnu99 -O0 -g -fPIC -Isrc"

./src/lua -v
./src/luac -v
./src/luac -p -l tests/e2e/run_all.lua >/dev/null
./src/luac -o validation-results/luac.out tests/e2e/run_all.lua
./src/luac -l -l validation-results/luac.out >/dev/null
rm -f validation-results/luac.out

./src/lua tests/e2e/run_all.lua
FUZZ_REQUIRE_UDATA=1 FUZZ_OPS="$FUZZ_OPS" ./src/lua tests/test_gc_fuzz.lua
EXTRA_CFLAGS="$COV_CFLAGS" EXTRA_LDFLAGS="$COV_LDFLAGS" ./scripts/run_gc_validation.sh release
make test-testes-basic

GCOV_BIN="${GCOV:-$(command -v gcov)}"

# Detect lcov >= 2.0 for --ignore-errors flags (older lcov 1.x rejects them).
LCOV_VER="$(lcov --version | awk '{print $NF}')"
LCOV_CAP_ARGS=()
LCOV_MERGE_ARGS=()
LCOV_EXT_ARGS=()
case "$LCOV_VER" in
  2.*|3.*)
    LCOV_CAP_ARGS=(--ignore-errors source,mismatch,inconsistent,gcov)
    LCOV_MERGE_ARGS=(--ignore-errors inconsistent,corrupt,mismatch)
    LCOV_EXT_ARGS=(--ignore-errors unused,inconsistent)
    ;;
esac

lcov --directory src --capture \
  --gcov-tool "$GCOV_BIN" \
  --output-file validation-results/coverage-base.info \
  --base-directory "$ROOT/src" --no-external \
  "${LCOV_CAP_ARGS[@]}"

echo "==== coverage pass 2: ltests build (LUA_DEBUG + negative checks + complete official testes) ===="
cleanup_gcda
EXTRA_CFLAGS="$COV_CFLAGS" EXTRA_LDFLAGS="$COV_LDFLAGS" ./scripts/build_with_ltests.sh linux
EXTRA_CFLAGS="$COV_CFLAGS" EXTRA_LDFLAGS="$COV_LDFLAGS" ./scripts/run_gc_validation.sh ltests
FUZZ_REQUIRE_UDATA=1 FUZZ_OPS="$FUZZ_OPS" ./src/lua tests/test_gc_fuzz.lua
(cd testes && ../src/lua gc.lua)
make test-testes

lcov --directory src --capture \
  --gcov-tool "$GCOV_BIN" \
  --output-file validation-results/coverage-ltests.info \
  --base-directory "$ROOT/src" --no-external \
  "${LCOV_CAP_ARGS[@]}"

echo "==== merge & extract src/* coverage ===="
lcov --add-tracefile validation-results/coverage-base.info \
     --add-tracefile validation-results/coverage-ltests.info \
     --output-file validation-results/coverage-merged.info \
     "${LCOV_MERGE_ARGS[@]}"

lcov --extract validation-results/coverage-merged.info "$ROOT/src/*" \
     --output-file validation-results/coverage.info \
     "${LCOV_EXT_ARGS[@]}"

cleanup_gcda
make clean

echo "==== coverage summary (validation-results/coverage.info) ===="
lcov --summary validation-results/coverage.info
