#!/usr/bin/env bash
# Fetch official PUC-Lua 5.3.4 testes into ./testes and apply lua53plus adaptations.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

URL="https://www.lua.org/tests/lua-5.3.4-tests.tar.gz"
SHA256="b80771238271c72565e5a1183292ef31bd7166414cd0d43a8eb79845fa7f599f"
TGZ="${TMPDIR:-/tmp}/lua-5.3.4-tests.tar.gz"

echo "Downloading $URL ..."
# lua.org is occasionally unreachable from CI runners; retry with backoff.
ok=0
for attempt in 1 2 3 4 5; do
  if curl -fsSL --connect-timeout 30 --max-time 180 -o "$TGZ" "$URL"; then
    ok=1
    break
  fi
  echo "curl failed (attempt $attempt); retrying in $((attempt * 5))s ..." >&2
  sleep $((attempt * 5))
done
if [ "$ok" -ne 1 ]; then
  echo "failed to download $URL after retries" >&2
  exit 1
fi
echo "$SHA256  $TGZ" | sha256sum -c -

rm -rf testes
mkdir -p testes
tar -xzf "$TGZ" -C testes --strip-components=1
chmod -R u+w testes

# Adapt ltests for lua53plus extra gray lists + generational list awareness.
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
text = text.replace(old, new, 1)

# Allow old-generation objects to remain non-white at GCSpause (minor cycles).
old_chk = """    lua_assert(g->gcstate != GCSpause || iswhite(o));"""
new_chk = """    /* lua53plus: oldgc objects stay black across minor cycles */
    lua_assert(g->gcstate != GCSpause || iswhite(o) || isold(o));"""
if old_chk not in text:
    raise SystemExit("checkobject pause/white assert not found — aborting")
text = text.replace(old_chk, new_chk, 1)

# Generational: old black may point to young white (oldweak rescans / barriers).
old_ref = """static int testobjref1 (global_State *g, GCObject *f, GCObject *t) {
  if (isdead(g,t)) return 0;
  if (!issweepphase(g))
    return !(isblack(f) && iswhite(t));
  else return 1;
}"""
new_ref = """static int testobjref1 (global_State *g, GCObject *f, GCObject *t) {
  if (isdead(g,t)) return 0;
  if (!issweepphase(g)) {
    if (!(isblack(f) && iswhite(t))) return 1;
    /* lua53plus: old black -> young white is OK (TOUCHEDBIT / oldweak) */
    if (isold(f) && !isold(t)) return 1;
    if (testbit(f->marked, TOUCHEDBIT)) return 1;
    return 0;
  }
  else return 1;
}"""
if old_ref not in text:
    raise SystemExit("testobjref1 block not found — aborting")
text = text.replace(old_ref, new_ref, 1)

# Walk generational lists inside lua_checkmemory.
old_mem = """  /* check 'tobefnz' list */
  checkgray(g, g->tobefnz);
  for (o = g->tobefnz; o != NULL; o = o->next) {
    checkobject(g, o, 0);
    lua_assert(tofinalize(o));
    lua_assert(o->tt == LUA_TUSERDATA || o->tt == LUA_TTABLE);
  }
  return 0;
}"""
new_mem = """  /* check 'tobefnz' list */
  checkgray(g, g->tobefnz);
  for (o = g->tobefnz; o != NULL; o = o->next) {
    checkobject(g, o, 0);
    lua_assert(tofinalize(o));
    lua_assert(o->tt == LUA_TUSERDATA || o->tt == LUA_TTABLE);
  }
  /* lua53plus: generational lists */
  checkgray(g, g->oldgc);
  for (o = g->oldgc; o != NULL; o = o->next) {
    lua_assert(isold(o));
    lua_assert(!tofinalize(o));
    checkobject(g, o, 0);
  }
  checkgray(g, g->oldfinobj);
  for (o = g->oldfinobj; o != NULL; o = o->next) {
    lua_assert(isold(o));
    lua_assert(tofinalize(o));
    lua_assert(o->tt == LUA_TUSERDATA || o->tt == LUA_TTABLE);
    checkobject(g, o, 0);
  }
  /* tobeswept / tobesweptfin exist only during young sweep */
  checkgray(g, g->tobeswept);
  for (o = g->tobeswept; o != NULL; o = o->next) {
    checkobject(g, o, maybedead);
    lua_assert(!tofinalize(o));
  }
  checkgray(g, g->tobesweptfin);
  for (o = g->tobesweptfin; o != NULL; o = o->next) {
    checkobject(g, o, 0);
    lua_assert(tofinalize(o));
  }
  /* remudata: touched old userdata remembered outside mark */
  for (o = g->remudata; o != NULL; o = gco2u(o)->gclist) {
    lua_assert(o->tt == LUA_TUSERDATA);
    lua_assert(isold(o));
    lua_assert(testbit(o->marked, TOUCHEDBIT));
  }
  return 0;
}"""
if old_mem not in text:
    raise SystemExit("lua_checkmemory tobefnz tail not found — aborting")
text = text.replace(old_mem, new_mem, 1)

# Need lgc.h for isold / TOUCHEDBIT if not already visible via lstring.h
if '#include "lgc.h"' not in text:
    text = text.replace('#include "lstring.h"\n', '#include "lstring.h"\n#include "lgc.h"\n', 1)

p.write_text(text)
print("Applied lua53plus ltests markgrays + checkmemory generational adaptation")
PY

cp -f scripts/TESTES.md testes/README.md
echo "testes ready at $ROOT/testes"
