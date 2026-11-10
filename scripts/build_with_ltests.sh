#!/usr/bin/env bash
# Rebuild lua53plus with official ltests (T module + lua_assert + debug alloc).
#
# Usage: ./scripts/build_with_ltests.sh [linux|macosx]
# Optional env:
#   EXTRA_CFLAGS / EXTRA_LDFLAGS  extra compiler/linker flags (-m32, -fsanitize=...)
#   CC                            compiler (default: gcc -std=gnu99, or cc on macosx)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
test -f testes/ltests/ltests.c || { echo "missing testes/; run scripts/fetch_testes.sh"; exit 1; }

PLAT="${1:-linux}"
case "$PLAT" in
  linux|macosx) ;;
  *)
    echo "usage: $0 [linux|macosx]" >&2
    echo "optional env: EXTRA_CFLAGS EXTRA_LDFLAGS CC" >&2
    exit 1
    ;;
esac

if [ -z "${CC:-}" ]; then
  if [ "$PLAT" = macosx ]; then
    CC=cc
  else
    CC="gcc -std=gnu99"
  fi
fi
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"
EXTRA_LDFLAGS="${EXTRA_LDFLAGS:-}"

make clean

# Quotes must survive Make -> shell -> gcc so the preprocessor sees a string literal.
USER_H_FLAG='-DLUA_USER_H=\"../testes/ltests/ltests.h\"'

# Direct compile: LUA_USER_H must be a real string literal here.
# Word-splitting of EXTRA_* and CC is intentional (flag lists / "gcc -std=gnu99").
# shellcheck disable=SC2086
$CC -O2 -Wall -Wextra -DLUA_COMPAT_5_2 \
  -DLUA_USER_H='"../testes/ltests/ltests.h"' \
  $EXTRA_CFLAGS \
  -I src -c -o testes/ltests/ltests.o testes/ltests/ltests.c

make "$PLAT" CC="$CC" MYCFLAGS="$USER_H_FLAG $EXTRA_CFLAGS" \
  MYLDFLAGS="$EXTRA_LDFLAGS" MYOBJS='../testes/ltests/ltests.o'

./src/lua -v
echo "Built with ltests (T module). Run: make test-testes"
