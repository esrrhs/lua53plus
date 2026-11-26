/* Internal GC regression/OOM harness. Not part of the library/release build.
 * Compile with exactly the same LUA_USER_H/ABI flags as liblua.a. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lstate.h"
#include "lgc.h"
#include "lfunc.h"
#include "lobject.h"
#include "lstring.h"
#include "ltable.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
typedef struct Alloc {
  size_t live, blocks, calls, failat, failures;
  int once;
} Alloc;
static void *allocf(void *ud, void *p, size_t old, size_t n) {
  Alloc *a = (Alloc *)ud;
  void *q;
  if (!p) old = 0; /* osize is a type tag for fresh objects */
  if (!n) {
    if (p) { a->live -= old; a->blocks--; free(p); }
    return NULL;
  }
  if (n > old && ++a->calls >= a->failat && a->failat) {
    a->failures++;
    if (a->once) a->failat = 0;
    return NULL;
  }
  q = realloc(p, n);
  if (q) { a->live = a->live - old + n; if (!p) a->blocks++; }
  return q;
}
static void checkmem(lua_State *L) {
#ifdef GC_WITH_LTESTS
  lua_checkmemory(L);
#else
  (void)L;
#endif
}
static void run(lua_State *L, const char *s) {
  int rc = luaL_dostring(L, s);
  if (rc) fprintf(stderr, "%s\n", lua_tostring(L, -1));
  CHECK(rc == LUA_OK);
}
static int newud(lua_State *L) { lua_newuserdata(L, 192); return 1; }
static void state(lua_State *L, int s) {
  lua_lock(L);
  luaC_runtilstate(L, bitmask(s));
  lua_unlock(L);
  checkmem(L);
}
static void cycle(lua_State *L) { state(L, GCSpropagate); state(L, GCSpause); }
static lua_State *prepare(Alloc *a) {
  lua_State *L = lua_newstate(allocf, a);
  CHECK(L);
  luaL_openlibs(L);
  lua_pushcfunction(L, newud); lua_setglobal(L, "newud");
  lua_gc(L, LUA_GCSTOP, 0);
  run(L, "roots={}; final={}; resurrect={}; nfin=0; "
         "mt={__gc=function(u) nfin=nfin+1; resurrect[#resurrect+1]=u end}; "
         "for i=1,3000 do roots[i]=newud(); final[i]=setmetatable({},mt) end; "
         "function work() local x={}; for i=1,40 do x[i]={i,i+1,i+2,u=newud()} end return x end");
  lua_gc(L, LUA_GCRESTART, 0);
  cycle(L);
  CHECK(G(L)->oldgc && G(L)->oldfinobj);
  return L;
}
static GCObject *root(lua_State *L, int i) {
  GCObject *o;
  lua_getglobal(L,"roots"); lua_rawgeti(L,-1,i);
  /* Internal stack value is independent of userdata header padding. */
  o = gcvalue(L->top - 1);
  lua_pop(L,2);
  return o;
}
static void latefinal(lua_State *L, int i) {
  lua_getglobal(L,"roots"); lua_rawgeti(L,-1,i);
  CHECK(isold(gcvalue(L->top-1)));
  lua_getglobal(L,"mt"); lua_setmetatable(L,-2); lua_pop(L,2);
  checkmem(L);
}
static void closecheck(lua_State *L, Alloc *a) {
  lua_close(L); CHECK(a->live == 0 && a->blocks == 0);
}
static void directed(void) {
  Alloc a = {0}; lua_State *L = prepare(&a);
  /* Includes userdata at different positions among non-TU nodes in oldgc. */
  run(L,"mt={__gc=mt.__gc}"); /* young metatable: mandatory-major exception */
  latefinal(L,1); latefinal(L,1500); latefinal(L,3000);
  CHECK(G(L)->oldfinobj);
  /* Enter bleach through the real needmajor transition, and interrupt with
     a full collection: mergeoldgen must splice the partly bleached lists. */
  G(L)->needmajor = 1;
  lua_gc(L, LUA_GCSTEP, 0);
  CHECK(G(L)->inbleach);
  checkmem(L);
  {
    int i;
    for(i=1;i<=3000;i++) {
      GCObject *o=root(L,i);
      if(isold(o) && !tofinalize(o)) { latefinal(L,i); break; }
    }
    CHECK(i<=3000); /* unlink old userdata while fintail is active */
  }
  lua_gc(L,LUA_GCCOLLECT,0); checkmem(L);
  CHECK(!G(L)->inbleach && G(L)->ismajor);
  cycle(L); CHECK(G(L)->oldgc);
  /* Full collection while GC is stopped must preserve survivor promotion. */
  lua_gc(L,LUA_GCSTOP,0);
  lua_gc(L,LUA_GCCOLLECT,0); checkmem(L);
  CHECK(G(L)->oldgc != NULL && !lua_gc(L,LUA_GCISRUNNING,0));
  lua_gc(L,LUA_GCRESTART,0);
  /* Excess surviving coroutines in oldweak (>256) must trigger incremental major bleach. */
  run(L,"do local tmp={}; for i=1,300 do tmp[i]=coroutine.create(function() coroutine.yield() end); coroutine.resume(tmp[i]) end "
        "collectgarbage('step', 5000); end");
  checkmem(L);
  CHECK(G(L)->oldweakcount >= 300);
  lua_gc(L,LUA_GCSTEP,0); checkmem(L);
  CHECK(G(L)->inbleach);
  while (G(L)->inbleach) { lua_gc(L,LUA_GCSTEP,0); checkmem(L); }
  state(L,GCSpause); checkmem(L);
  CHECK(G(L)->oldweakcount < 32);
  G(L)->needmajor = 1;
  lua_gc(L,LUA_GCSTEP,0); CHECK(G(L)->inbleach);
  while (G(L)->inbleach) { lua_gc(L,LUA_GCSTEP,0); checkmem(L); }
  state(L,GCSpause); checkmem(L);
  run(L,"roots=nil; final=nil");
  lua_gc(L,LUA_GCCOLLECT,0); checkmem(L);
  run(L,"assert(nfin==3004); resurrect=nil; mt=nil");
  lua_gc(L,LUA_GCCOLLECT,0); lua_gc(L,LUA_GCCOLLECT,0);
  checkmem(L); closecheck(L,&a);
  puts("directed: old userdata unlink / incremental bleach / partial merge / resurrection OK");
}
static void phase(lua_State *L, int p) {
  if (p == 1) state(L,GCSpropagate);
  if (p == 2) {
    lua_gc(L,LUA_GCSTOP,0);
    run(L,"young={}; youngfin={}; for i=1,1500 do young[i]=newud(); youngfin[i]=debug.setmetatable(newud(),mt) end");
    lua_gc(L,LUA_GCRESTART,0);
    state(L,GCSswpallgc);
    CHECK(G(L)->tobeswept && G(L)->tobesweptfin);
  }
  if (p == 3) {
    G(L)->needmajor = 1; lua_gc(L,LUA_GCSTEP,0);
    CHECK(G(L)->inbleach);
  }
  if (p == 4) {
    run(L,"final=nil"); lua_gc(L,LUA_GCCOLLECT,0);
    run(L,"assert(nfin==3000 and #resurrect==3000)");
    cycle(L); /* resurrected objects can now be promoted again */
  }
  checkmem(L);
}
static void oom(void) {
  int p, mode, n, errors=0, successes=0;
  const char *names[] = {"old-pause","propagate","young-sweep","partial-bleach","resurrected"};
  /* Fresh state for every fail point: errors cannot bias later coverage.
     Both persistent failure (including emergency retry) and one-shot failure. */
  for (p=0;p<5;p++) for (mode=0;mode<2;mode++) {
    int e=0, s=0, f=0;
    for (n=1;n<=48;n++) {
      Alloc a = {0}; lua_State *L = prepare(&a);
      phase(L,p);
      lua_getglobal(L,"work"); /* function/stack ready before enabling failure */
      a.once=mode; a.failat=a.calls+(size_t)n;
      {
        int rc=lua_pcall(L,0,1,0);
        if (rc!=LUA_OK && rc!=LUA_ERRMEM) fprintf(stderr,"phase=%d mode=%d failpoint=%d rc=%d error=%s\n",p,mode,n,rc,lua_tostring(L,-1));
        CHECK(rc==LUA_OK || rc==LUA_ERRMEM);
        if (rc==LUA_ERRMEM) { CHECK(a.failures); e++; }
        else s++; /* one-shot failure may be rescued by emergency fullgc */
      }
      if (a.failures) f++;
      a.failat=0; lua_pop(L,1);
      checkmem(L);
      run(L,"assert(type(work())=='table')");
      lua_gc(L,LUA_GCCOLLECT,0); checkmem(L);
      closecheck(L,&a);
    }
    CHECK(f==48); if (!mode) CHECK(e==48); else CHECK(s>0);
    errors+=e; successes+=s;
    printf("oom: %s %s injected=%d ERRMEM=%d OK=%d, recovery+close leak-free\n",names[p],mode?"one-shot":"persistent",f,e,s);
  }
  CHECK(errors && successes);
}
static int collectcall(lua_State *L) { lua_gc(L,LUA_GCCOLLECT,0); return 0; }
static int oomfinal(lua_State *L) {
  Alloc *a; void *ud;
  (void)lua_getallocf(L,&ud); a=(Alloc *)ud;
  lua_getglobal(L,"resurrect"); lua_pushvalue(L,1); lua_rawseti(L,-2,1); lua_pop(L,1);
  /* Arm at the precise post-resurrection allocation, not at an earlier GC
     setup allocation. Persistent OOM propagates ERRMEM (not ERRGCMM: GCTM
     only wraps runtime errors); one-shot may succeed after emergency GC. */
  a->failat=a->calls+1;
  lua_newuserdata(L,1024);
  return 0;
}
static void finalizer_oom(void) {
  int mode;
  for(mode=0;mode<2;mode++) {
    Alloc a={0}; lua_State *L=lua_newstate(allocf,&a); int rc;
    CHECK(L); luaL_openlibs(L); lua_gc(L,LUA_GCSTOP,0);
    lua_createtable(L,1,0); lua_setglobal(L,"resurrect");
    lua_newuserdata(L,192); lua_newtable(L);
    lua_pushcfunction(L,oomfinal); lua_setfield(L,-2,"__gc");
    lua_setmetatable(L,-2); lua_pop(L,1);
    lua_pushcfunction(L,collectcall); a.once=mode;
    rc=lua_pcall(L,0,0,0);
    CHECK(a.failures>0);
    if(!mode) CHECK(rc==LUA_ERRMEM);
    else CHECK(rc==LUA_OK || rc==LUA_ERRMEM);
    a.failat=0; if(rc) lua_pop(L,1);
    lua_getglobal(L,"resurrect"); lua_rawgeti(L,-1,1);
    CHECK(lua_isuserdata(L,-1)); lua_pop(L,2); checkmem(L);
    run(L,"resurrect=nil; assert(1+1==2)");
    lua_gc(L,LUA_GCCOLLECT,0); checkmem(L); closecheck(L,&a);
    printf("oom: inside finalizer after resurrection %s rc=%d recovered leak-free\n",mode?"one-shot":"persistent",rc);
  }
}
#ifdef GC_WITH_LTESTS
static void corrupt(const char *kind) {
  Alloc a = {0}; lua_State *L=prepare(&a);
  if (!strcmp(kind,"listprev")) {
    GCObject *o=root(L,1500); CHECK(isold(o)); gco2u(o)->listprev=o;
  }
  else if (!strcmp(kind,"barrier")) {
    GCObject *o=root(L,1500);
    lua_getglobal(L,"roots"); lua_rawgeti(L,-1,1500);
    lua_newtable(L); lua_setuservalue(L,-2); lua_pop(L,2);
    CHECK(G(L)->remudata==o);
    G(L)->remudata=gco2u(o)->gclist; gco2u(o)->gclist=NULL;
    resetbit(o->marked,TOUCHEDBIT); /* intentionally lose remembered edge */
  }
  else if (!strcmp(kind,"mandatory-major")) {
    run(L,"mt={__gc=mt.__gc}"); latefinal(L,1500);
    CHECK(G(L)->needmajor); G(L)->needmajor=0;
  }
  else if (!strcmp(kind,"primary-alias")) {
    G(L)->tobeswept=G(L)->oldgc;
  }
  else if (!strcmp(kind,"remuv")) {
    run(L,"local x={}; function getx() return x end; function setx(v) x=v end");
    cycle(L); run(L,"setx({})"); CHECK(G(L)->remuv);
    G(L)->remuv=NULL; /* uv->remnext != uv remains true (upisinrem), breaking membership */
  }
  else if (!strcmp(kind,"pause")) {
    GCObject *o=root(L,1500); resetbit(o->marked,BLACKBIT);
  }
  else CHECK(0);
  checkmem(L);
  fprintf(stderr,"checker FAILED to reject corruption: %s\n",kind); exit(2);
}
#endif
static int adv_swpallgc(lua_State *L) {
  lua_gc(L, LUA_GCRESTART, 0);
  state(L, GCSpropagate);
  state(L, GCSswpallgc);
  lua_gc(L, LUA_GCSTOP, 0); /* freeze sweep until LoadDebug + fn() set white Proto->cache */
  return 0;
}

static void coverage_edges(void) {
  /* 1. remudata surviving into restartcollection (clearremlists mark=1) +
        out-of-line luaH_getshortstr / luaH_getstr / luaH_get entry points */
  {
    Alloc a = {0}; lua_State *L = prepare(&a);
    Table *gt; TString *ks; TValue tvk;
    run(L, "kshort = 321; debug.setmetatable(roots[10], { tag = 'ud_mt' }); "
           "debug.setuservalue(roots[10], { uv_ok = 777 })");
    /* Also exercise old CClosure forward-to-grayagain barrier (getgclist LUA_TCCL) */
    lua_newtable(L);
    lua_pushcclosure(L, adv_swpallgc, 1);
    lua_setglobal(L, "old_ccl");
    cycle(L);
    lua_getglobal(L, "old_ccl");
    lua_newtable(L);
    CHECK(lua_setupvalue(L, -2, 1) != NULL);
    lua_pop(L, 1);
    cycle(L);
    run(L, "debug.setmetatable(roots[10], { tag = 'ud_mt' }); "
           "debug.setuservalue(roots[10], { uv_ok = 777 })");
    CHECK(G(L)->remudata != NULL);
    checkmem(L);
    lua_getglobal(L, "_G");
    gt = hvalue(L->top - 1);
    ks = luaS_new(L, "kshort");
    setsvalue(L, &tvk, ks);
    CHECK(ivalue(luaH_getshortstr(gt, ks)) == 321);
    CHECK(ivalue(luaH_getstr(gt, ks)) == 321);
    CHECK(ivalue(luaH_get(gt, &tvk)) == 321);
    lua_pop(L, 1);
    cycle(L); /* restartcollection -> clearremlists(g, 1) marks metatable + uservalue */
    run(L, "assert(debug.getmetatable(roots[10]).tag == 'ud_mt' and "
           "debug.getuservalue(roots[10]).uv_ok == 777)");

    /* 2. TOUCHEDBIT udata in sweeptobeswept & sweepfinobj, TOUCHEDBIT table in sweepfinobj */
    lua_gc(L, LUA_GCSTOP, 0);
    run(L, "yu = newud(); yufin = debug.setmetatable(newud(), mt); ytfin = setmetatable({}, mt); "
           "ypad = {}; ypadfin = {}; "
           "for i = 1, 300 do ypad[i] = newud(); ypadfin[i] = setmetatable({}, mt) end");
    lua_gc(L, LUA_GCRESTART, 0);
    state(L, GCSswpallgc);
    lua_gc(L, LUA_GCSTOP, 0); /* keep yu in tobeswept while Lua mutates its uservalue */
    CHECK(G(L)->tobeswept && G(L)->tobesweptfin);
    run(L, "debug.setuservalue(yu, { a = 11 }); "
           "debug.setuservalue(yufin, { b = 22 }); "
           "ytfin.c = { d = 33 }");
    checkmem(L);
    lua_gc(L, LUA_GCRESTART, 0);
    state(L, GCSpause);
    cycle(L);
    run(L, "assert(debug.getuservalue(yu).a == 11 and "
           "debug.getuservalue(yufin).b == 22 and ytfin.c.d == 33)");

    /* 3. oldweakcount > (lastmajweak << 1) on >10,000-object old heap (no earlier || short-circuit) */
    run(L, "extra_old = {}; for i = 1, 8000 do extra_old[i] = { i } end");
    lua_gc(L, LUA_GCCOLLECT, 0);
    run(L, "wmt = { __mode = 'v' }; wpool = {}; for i = 1, 300 do wpool[i] = setmetatable({}, wmt) end");
    cycle(L); /* minor cycle promotes 300 weak tables into oldweak without exceeding +25% oldcount */
    CHECK(!G(L)->ismajor && G(L)->oldweakcount >= 300);
    lua_gc(L, LUA_GCSTEP, 0); /* hits oldweakcount > (lastmajweak << 1) -> startbleach */
    CHECK(G(L)->inbleach);
    while (G(L)->inbleach) { lua_gc(L, LUA_GCSTEP, 0); checkmem(L); }
    state(L, GCSpause);

    /* 4. >192 MB setpause 24 MB cap (both oldgc != NULL and emergency fullgc oldgc == NULL) */
    lua_newuserdata(L, 200u * 1024u * 1024u);
    lua_setglobal(L, "bigud");
    lua_gc(L, LUA_GCCOLLECT, 0); /* hits maxpause = 24MB with oldgc != NULL */
    CHECK(G(L)->oldgc != NULL);
    a.once = 1;
    a.failat = a.calls + 1;
    (void)lua_newuserdata(L, 64); /* triggers emergency luaC_fullgc(L, 1) -> oldgc == NULL, >192MB */
    lua_pop(L, 1);
    a.failat = 0;
    CHECK(G(L)->oldgc == NULL);
    lua_pushnil(L);
    lua_setglobal(L, "bigud");
    lua_gc(L, LUA_GCCOLLECT, 0);

    /* 5. lua_close (luaC_freeallobjects) mid-sweep while both tobeswept and tobesweptfin are active */
    phase(L, 2);
    CHECK(G(L)->tobeswept && G(L)->tobesweptfin);
    closecheck(L, &a);
  }

  /* 6. Old tables dynamically made weak ('v' & 'k') with 0 clearable entries in atomic,
        non-promoting stopped-sweep barrierback & checkfinalizer sweepgc cursor,
        udata2finalize sweepgc == &o->next, and Proto->cache drop in sweeptobeswept */
  {
    Alloc a = {0}; lua_State *L = lua_newstate(allocf, &a);
    CHECK(L);
    luaL_openlibs(L);
    lua_pushcfunction(L, adv_swpallgc);
    lua_setglobal(L, "adv_swpallgc");

    /* 6a. traverseweakvalue / traverseephemeron else if (isold(h)) with hasclears == 0 */
    run(L, "wv = {}; wk = {}; mt_v = {}; mt_k = {}; pad_old = {}; "
           "for i = 1, 2000 do pad_old[i] = { i } end");
    lua_gc(L, LUA_GCCOLLECT, 0);
    run(L, "mt_v.__mode = 'v'; rawset(mt_k, '__mode', 'k')"); /* hits lvm.c:221 & lapi.c:813 */
    lua_gc(L, LUA_GCCOLLECT, 0); /* clear needmajor while wv/wk remain strong old tables */
    state(L, GCSpropagate);
    CHECK(!G(L)->ismajor);
    run(L, "keep_y = {}; setmetatable(wv, mt_v); setmetatable(wk, mt_k); "
           "wv.only = keep_y; wk[keep_y] = 1");
    state(L, GCSpause);
    checkmem(L);
    run(L, "assert(wv.only == keep_y and wk[keep_y] == 1)");

    /* 6b. Non-promoting stopped sweep: luaC_barrierback_ makewhite & checkfinalizer sweepgc cursor */
    lua_gc(L, LUA_GCSTOP, 0);
    run(L, "gc_mt2 = { __gc = function() end }; s1 = {}");
    state(L, GCSpropagate);
    lua_newtable(L); /* exact head of g->allgc after mergeoldgen, kept live on stack */
    state(L, GCSswpallgc);
    CHECK(G(L)->tobeswept == NULL && G(L)->sweepgc == &gcvalue(L->top - 1)->next);
    lua_getglobal(L, "gc_mt2");
    lua_setmetatable(L, -2); /* hits g->sweepgc == &o->next -> sweeptolive */
    lua_pop(L, 1);
    run(L, "s1.child = { 42 }"); /* hits luaC_barrierback_ makewhite */
    state(L, GCSpause);
    checkmem(L);
    lua_gc(L, LUA_GCRESTART, 0);

    /* 6c. Proto in tobeswept turned gray via LoadDebug barrier + white cache cleared in sweeptobeswept */
    run(L, "local d = string.dump(function() local loc = 1; return function() return loc end end, false); "
           "for sp = #d - 24, #d - 2, 2 do "
           "  local idx = 0 "
           "  local fn = assert(load(function() "
           "    idx = idx + 1 "
           "    if idx == 1 then return d:sub(1, sp) end "
           "    if idx == 2 then adv_swpallgc(); return d:sub(sp + 1) end "
           "    return nil "
           "  end)) "
           "  fn() "
           "  collectgarbage('restart') "
           "  while not collectgarbage('step', 1000) do end "
           "end");
    state(L, GCSpause);
    checkmem(L);

    /* 6d. udata2finalize hitting g->sweepgc == &o->next during GCSswptobefnz */
    lua_gc(L, LUA_GCSTOP, 0);
    run(L, "fin_cnt = 0; fin_mt = { __gc = function() fin_cnt = fin_cnt + 1 end }; "
           "for i = 1, 4500 do setmetatable({}, fin_mt) end");
    lua_gc(L, LUA_GCRESTART, 0);
    state(L, GCSswptobefnz);
    while (G(L)->gcstate == GCSswptobefnz)
      lua_gc(L, LUA_GCSTEP, 0);
    state(L, GCSpause);
    run(L, "assert(fin_cnt == 4500)");
    lua_gc(L, LUA_GCCOLLECT, 0);
    checkmem(L);
    closecheck(L, &a);
  }
  puts("coverage_edges: remudata / mid-sweep close / 0-clear oldweak / 24MB pause / proto cache OK");
}

int main(int argc, char **argv) {
#ifdef GC_WITH_LTESTS
  if (argc==2) { corrupt(argv[1]); return 2; }
#else
  (void)argc; (void)argv;
#endif
  directed(); coverage_edges(); oom(); finalizer_oom(); return 0;
}
