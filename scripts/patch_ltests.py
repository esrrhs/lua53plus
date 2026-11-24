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
new_chk = """    lua_assert(g->gcstate != GCSpause || validpause(g, o));"""
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
new_ref = """/* Debug-only membership checks: never compiled into release Lua. */
static GCObject *graynext (GCObject *o) {
  switch (o->tt) {
    case LUA_TTABLE: return gco2t(o)->gclist;
    case LUA_TLCL: return gco2lcl(o)->gclist;
    case LUA_TCCL: return gco2ccl(o)->gclist;
    case LUA_TPROTO: return gco2p(o)->gclist;
    case LUA_TTHREAD: return gco2th(o)->gclist;
    case LUA_TUSERDATA: return gco2u(o)->gclist;
    default: lua_assert(0); return NULL;
  }
}

static int ingray (GCObject *head, GCObject *o) {
  for (; head; head = graynext(head)) if (head == o) return 1;
  return 0;
}

static int validpause (global_State *g, GCObject *o) {
  if (iswhite(o)) return !isold(o);
  if (!isold(o)) return 0;
  if (isblack(o)) return 1;
  /* startbleach drops remembered lists; remaining old objects retain color
     until bleachstep moves them to allgc/finobj. */
  return testbit(o->marked, TOUCHEDBIT) &&
         (g->inbleach || ingray(g->grayagain, o));
}

static int testobjref1 (global_State *g, GCObject *f, GCObject *t) {
  if (isdead(g,t)) return 0;
  if (issweepphase(g) || !(isblack(f) && iswhite(t))) return 1;
  /* During bleach, barriers deliberately do nothing; all old objects will
     be whitened before restartcollection. Never allow this during mark. */
  if (g->inbleach && g->gcstate == GCSpause && isold(f)) return 1;
  /* Surviving threads/weak tables are whitened, not promoted. Their
     incoming edges need no barrier: restartcollection rescans oldweak.
     mainthread is independently whitened at swpend and marked as a root. */
  if (!keepinvariant(g) && (t == obj2gco(g->mainthread) ||
                           ingray(g->oldweak, t))) return 1;
  /* checkfinalizer may remove a remembered old object, recolor it black
     and set needmajor. A major is then mandatory BEFORE the next mark:
     singlestep(GCSpause) bleaches/merges all old objects first. */
  if (!keepinvariant(g) && g->needmajor && isold(f)) return 1;
  /* Only userdata stays black after a non-mark forward barrier. Tables,
     closures and protos must instead be gray on grayagain. */
  if (!keepinvariant(g) && f->tt == LUA_TUSERDATA &&
      testbit(f->marked, TOUCHEDBIT) && ingray(g->remudata, f)) return 1;
  return 0;
}"""
if old_ref not in text:
    raise SystemExit("testobjref1 block not found — aborting")
text = text.replace(old_ref, new_ref, 1)

# Keep the original failed-edge diagnostic visible even when CI redirects stdout.
text = text.replace('  if (!r1) {',
                    '  if (!r1) {\n    printf("GC reference invariant failed: ");', 1)
text = text.replace('    printf("\\n");\n  }\n  return r1;',
                    '    printf("\\n");\n    fflush(stdout);\n  }\n  return r1;', 1)

# Closed UpVals have no GC color; only the particular remembered edge is exempt.
old_uv = """      if (!upisopen(uv))  /* only closed upvalues matter to invariant */
        checkvalref(g, clgc, uv->v);"""
new_uv = """      if (!upisopen(uv)) {
        UpVal *r;
        for (r = g->remuv; r && r != uv; r = r->remnext) { /* empty */ }
        lua_assert((r == uv) == (uv->inrem != 0));
        if (!keepinvariant(g) && r == uv && uv->inrem) {
          lua_assert(!iscollectable(uv->v) ||
                     (righttt(uv->v) && !isdead(g, gcvalue(uv->v))));
        }
        else checkvalref(g, clgc, uv->v);
      }"""
if old_uv not in text: raise SystemExit("closed upvalue check not found")
text = text.replace(old_uv, new_uv, 1)

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
    lua_assert(isold(o) || issweepphase(g));
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

helpers = """
/* Each primary list is acyclic; singly-linked lists intersect iff their
   tails match. This checks disjointness in O(heap), not O(heap squared). */
static void checkgenlists (global_State *g) {
  GCObject *heads[8], *tails[8], *o, *prev;
  UpVal *u, *v;
  int i, j;
  heads[0] = g->allgc; heads[1] = g->finobj;
  heads[2] = g->tobefnz; heads[3] = g->fixedgc;
  heads[4] = g->oldgc; heads[5] = g->oldfinobj;
  heads[6] = g->tobeswept; heads[7] = g->tobesweptfin;
  for (i = 0; i < 8; i++) {
    GCObject *slow = heads[i], *fast = heads[i];
    while (fast && fast->next) {
      slow = slow->next; fast = fast->next->next;
      lua_assert(slow != fast);
    }
    tails[i] = NULL;
    for (o = heads[i]; o; o = o->next) tails[i] = o;
    for (j = 0; j < i; j++)
      lua_assert(!tails[i] || tails[i] != tails[j]);
  }
  for (i = 0; i < 8; i++) {
    if (i == 4) continue;
    for (o = heads[i]; o; o = o->next) {
      if (o->tt == LUA_TTABLE) lua_assert(gco2t(o)->listprev == NULL);
      if (o->tt == LUA_TUSERDATA) lua_assert(gco2u(o)->listprev == NULL);
    }
  }
  prev = NULL;
  for (o = g->oldgc; o; prev = o, o = o->next) {
    if (o->tt == LUA_TTABLE) lua_assert(gco2t(o)->listprev == prev);
    if (o->tt == LUA_TUSERDATA) lua_assert(gco2u(o)->listprev == prev);
  }
  u = v = g->remuv;
  while (v && v->remnext) {
    u = u->remnext; v = v->remnext->remnext;
    lua_assert(u != v);
  }
  for (u = g->remuv; u; u = u->remnext) {
    lua_assert(u->inrem && !upisopen(u));
    /* refcount == 0 is intentional: deferred freeing by clearremlists. */
  }
  {
    GCObject *slow = g->remudata, *fast = g->remudata;
    while (fast && graynext(fast)) {
      slow = graynext(slow); fast = graynext(graynext(fast));
      lua_assert(slow != fast);
    }
  }
}

"""
text = text.replace('int lua_checkmemory (lua_State *L) {',
                    helpers + 'int lua_checkmemory (lua_State *L) {', 1)
text = text.replace('  markgrays(g);', '  checkgenlists(g);\n  markgrays(g);', 1)

p.write_text(text)
print("Applied lua53plus ltests markgrays + checkmemory generational adaptation")
