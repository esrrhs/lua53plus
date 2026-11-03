#!/usr/bin/env bash
# Fetch official PUC-Lua 5.3.4 testes into ./testes and apply lua53plus adaptations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

URL="https://www.lua.org/tests/lua-5.3.4-tests.tar.gz"
SHA256="b80771238271c72565e5a1183292ef31bd7166414cd0d43a8eb79845fa7f599f"
TGZ="${TMPDIR:-/tmp}/lua-5.3.4-tests.tar.gz"

echo "Downloading $URL ..."
curl -fsSL -o "$TGZ" "$URL"
echo "$SHA256  $TGZ" | sha256sum -c -

rm -rf testes
mkdir -p testes
tar -xzf "$TGZ" -C testes --strip-components=1
chmod -R u+w testes

# Adapt ltests for lua53plus extra gray lists (grayatomic / oldweak).
python3 - <<'PY'
from pathlib import Path
p = Path("testes/ltests/ltests.c")
text = p.read_text()
old = """static void markgrays (global_State *g) {
  if (!keepinvariant(g)) return;
  checkgraylist(g, g->gray);
  checkgraylist(g, g->grayagain);
  checkgraylist(g, g->weak);
  checkgraylist(g, g->ephemeron);
  checkgraylist(g, g->allweak);
}"""
new = """static void markgrays (global_State *g) {
  if (!keepinvariant(g)) return;
  checkgraylist(g, g->gray);
  checkgraylist(g, g->grayagain);
  checkgraylist(g, g->grayatomic);  /* lua53plus: threads/weaks deferred to atomic */
  checkgraylist(g, g->oldweak);     /* lua53plus: surviving threads/weaks */
  checkgraylist(g, g->weak);
  checkgraylist(g, g->ephemeron);
  checkgraylist(g, g->allweak);
}"""
if old not in text:
    raise SystemExit("markgrays block not found in official ltests.c — aborting")
p.write_text(text.replace(old, new, 1))
print("Applied lua53plus ltests markgrays adaptation")
PY

cp -f scripts/TESTES.md testes/README.md
echo "testes ready at $ROOT/testes"
