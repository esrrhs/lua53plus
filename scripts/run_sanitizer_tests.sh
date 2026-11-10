#!/usr/bin/env bash
# Build lua53plus with AddressSanitizer + UndefinedBehaviorSanitizer and run
# e2e, GC fuzz (t_udata required), and official PUC testes.
#
# Usage: ./scripts/run_sanitizer_tests.sh [linux|macosx]
# Optional env:
#   BITS=64|32              default 64 (32 is Linux only; needs gcc-multilib)
#   DETECT_LEAKS=1|0        default 1 on Linux, 0 on macOS (LSan unsupported)
#   RUN_FULL_TESTES=1|0     default 1 (rebuild with ltests and run complete suite)
#   FUZZ_OPS                default 6000
#   EXTRA_CFLAGS / EXTRA_LDFLAGS / CC
#   FETCH_TESTES=1          force re-fetch official testes
#
# Sanitizer options always include halt_on_error=1 so findings fail the run.
# Do not set exitcode=0; that would swallow ASan/UBSan errors.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLAT="${1:-linux}"
case "$PLAT" in
  linux|macosx) ;;
  *)
    echo "usage: $0 [linux|macosx]" >&2
    exit 1
    ;;
esac

BITS="${BITS:-64}"
FUZZ_OPS="${FUZZ_OPS:-6000}"
RUN_FULL_TESTES="${RUN_FULL_TESTES:-1}"
FETCH_TESTES="${FETCH_TESTES:-0}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:-}"

if [ "$BITS" = 32 ]; then
  if [ "$PLAT" != linux ]; then
    echo "BITS=32 is only supported with the linux target" >&2
    exit 1
  fi
  EXTRA_CFLAGS="-m32 $EXTRA_CFLAGS"
  EXTRA_LDFLAGS="-m32 $EXTRA_LDFLAGS"
fi

if [ -z "${DETECT_LEAKS:-}" ]; then
  if [ "$PLAT" = macosx ]; then
    DETECT_LEAKS=0
  else
    DETECT_LEAKS=1
  fi
fi

# Baseline options: errors must fail the process. Leak detection is
# conditioned above; macOS does not provide a usable LSan.
export ASAN_OPTIONS="detect_leaks=${DETECT_LEAKS}:halt_on_error=1:detect_stack_use_after_return=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"
export FUZZ_OPS
export FUZZ_REQUIRE_UDATA=1

SAN_CFLAGS="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -DLUA_USE_APICHECK -include assert.h -Dlua_assert=assert $EXTRA_CFLAGS"
SAN_LDFLAGS="-fsanitize=address,undefined $EXTRA_LDFLAGS"
UDATA_CFLAGS="-std=gnu99 -O1 -g -fPIC -Isrc -fsanitize=address,undefined -fno-omit-frame-pointer $EXTRA_CFLAGS"

echo "==== sanitizer build ($PLAT bits=$BITS leaks=$DETECT_LEAKS) ===="
echo "ASAN_OPTIONS=$ASAN_OPTIONS"
echo "UBSAN_OPTIONS=$UBSAN_OPTIONS"
make clean
make "$PLAT" MYCFLAGS="$SAN_CFLAGS" MYLDFLAGS="$SAN_LDFLAGS"
# shellcheck disable=SC2086
rm -f tests/t_udata.so
make test-udata TEST_UDATA_CFLAGS="$UDATA_CFLAGS" TEST_UDATA_LDFLAGS="-shared $SAN_LDFLAGS"
./src/lua -v

echo "==== e2e (ASan+UBSan) ===="
./src/lua tests/e2e/run_all.lua

echo "==== GC fuzz (ASan+UBSan, FUZZ_REQUIRE_UDATA=1, ops=$FUZZ_OPS) ===="
./src/lua tests/test_gc_fuzz.lua

if [ ! -f testes/all.lua ] || [ "$FETCH_TESTES" = 1 ]; then
  echo "==== fetch official testes ===="
  ./scripts/fetch_testes.sh
fi

echo "==== official testes basic (_U=true, ASan+UBSan) ===="
make test-testes-basic

if [ "$RUN_FULL_TESTES" = 1 ]; then
  echo "==== rebuild with ltests + official testes complete (_port=true) ===="
  # ltests supplies lua_assert; do not also force -Dlua_assert=assert.
  EXTRA_CFLAGS="-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer $EXTRA_CFLAGS" \
  EXTRA_LDFLAGS="-fsanitize=address,undefined $EXTRA_LDFLAGS" \
    ./scripts/build_with_ltests.sh "$PLAT"
  make test-testes TESTES_LIBS_CFLAGS="-Wall -std=gnu99 -O1 -g -fPIC -shared -I../../src -fsanitize=address,undefined $EXTRA_CFLAGS"
fi

echo "==== sanitizer tests passed (plat=$PLAT bits=$BITS leaks=$DETECT_LEAKS full=$RUN_FULL_TESTES) ===="
