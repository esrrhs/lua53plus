#!/usr/bin/env bash
# Rebuild lua53plus with official ltests (T module + lua_assert + debug alloc).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
test -f testes/ltests/ltests.c || { echo "missing testes/; run scripts/fetch_testes.sh"; exit 1; }

PLAT="${1:-linux}"
case "$PLAT" in
  linux|macosx) ;;
  *) echo "usage: $0 [linux|macosx]"; exit 1;;
esac

make clean

# Quotes must survive Make -> shell -> gcc so the preprocessor sees a string literal.
USER_H_FLAG='-DLUA_USER_H=\"../testes/ltests/ltests.h\"'

gcc -std=gnu99 -O2 -Wall -Wextra -DLUA_COMPAT_5_2 \
  -DLUA_USER_H='"../testes/ltests/ltests.h"' \
  -I src -c -o testes/ltests/ltests.o testes/ltests/ltests.c

make "$PLAT" MYCFLAGS="$USER_H_FLAG" MYOBJS='../testes/ltests/ltests.o'

./src/lua -v
echo "Built with ltests (T module). Run: make test-testes"
