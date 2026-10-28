/*
** $Id: lgc.c,v 2.215 2016/12/22 13:08:50 roberto Exp $
** Garbage Collector
** See Copyright Notice in lua.h
*/

#define lgc_c
#define LUA_CORE

#include "lprefix.h"


#include <string.h>

#include "lua.h"

#include "ldebug.h"
#include "ldo.h"
#include "lfunc.h"
#include "lgc.h"
#include "lmem.h"
#include "lobject.h"
#include "lstate.h"
#include "lstring.h"
#include "ltable.h"
#include "ltm.h"


/*
** internal state for collector while inside the atomic phase. The
** collector should never be in this state while running regular code.
*/
#define GCSinsideatomic		(GCSpause + 1)

/*
** cost of sweeping one element (the size of a small object divided
** by some adjust for the sweep speed)
*/
#define GCSWEEPCOST	((sizeof(TString) + 4) / 4)

/* maximum number of elements to sweep in each single step */
#define GCSWEEPMAX	(cast_int((GCSTEPSIZE / GCSWEEPCOST) / 4))

/* cost of calling one finalizer */
#define GCFINALIZECOST	GCSWEEPCOST


/*
** macro to adjust 'stepmul': 'stepmul' is actually used like
** 'stepmul / STEPMULADJ' (value chosen by tests)
*/
#define STEPMULADJ		200


/*
** macro to adjust 'pause': 'pause' is actually used like
** 'pause / PAUSEADJ' (value chosen by tests)
*/
#define PAUSEADJ		100


/*
** 'makewhite' erases all color bits then sets only the current white
** bit
*/
#define maskcolors	(~(bitmask(BLACKBIT) | WHITEBITS))
#define makewhite(g,x)	\
 (x->marked = cast_byte((x->marked & maskcolors) | luaC_white(g)))

#define white2gray(x)	resetbits(x->marked, WHITEBITS)
#define black2gray(x)	resetbit(x->marked, BLACKBIT)


#define valiswhite(x)   (iscollectable(x) && iswhite(gcvalue(x)))

#define checkdeadkey(n)	lua_assert(!ttisdeadkey(gkey(n)) || ttisnil(gval(n)))


#define checkconsistency(obj)  \
  lua_longassert(!iscollectable(obj) || righttt(obj))


#define markvalue(g,o) { checkconsistency(o); \
  if (valiswhite(o)) reallymarkobject(g,gcvalue(o)); }

#define markobject(g,t)	{ if (iswhite(t)) reallymarkobject(g, obj2gco(t)); }

/*
** mark an object that can be NULL (either because it is really optional,
** or it was stripped as debug info, or inside an uncompleted structure)
*/
#define markobjectN(g,t)	{ if (t) markobject(g,t); }

static void reallymarkobject (global_State *g, GCObject *o);


/*
** {======================================================
** Generic functions
** =======================================================
*/


/*
** one after last element in a hash array
*/
#define gnodelast(h)	gnode(h, cast(size_t, sizenode(h)))


/*
** link collectable object 'o' into list pointed by 'p'
*/
#define linkgclist(o,p)	((o)->gclist = (p), (p) = obj2gco(o))


static GCObject **getgclist (GCObject *o) {
  switch (o->tt) {
    case LUA_TTABLE: return &gco2t(o)->gclist;
    case LUA_TLCL: return &gco2lcl(o)->gclist;
    case LUA_TCCL: return &gco2ccl(o)->gclist;
    case LUA_TTHREAD: return &gco2th(o)->gclist;
    case LUA_TPROTO: return &gco2p(o)->gclist;
    default: lua_assert(0); return NULL;
  }
}


/*
** If key is not marked, mark its entry as dead. This allows key to be
** collected, but keeps its entry in the table.  A dead node is needed
** when Lua looks up for a key (it may be part of a chain) and when
** traversing a weak table (key might be removed from the table during
** traversal). Other places never manipulate dead keys, because its
** associated nil value is enough to signal that the entry is logically
** empty.
*/
static void removeentry (Node *n) {
  lua_assert(ttisnil(gval(n)));
  if (valiswhite(gkey(n)))
    setdeadvalue(wgkey(n));  /* unused and unmarked key; remove it */
}


/*
** tells whether a key or value can be cleared from a weak
** table. Non-collectable objects are never removed from weak
** tables. Strings behave as 'values', so are never removed too. for
** other objects: if really collected, cannot keep them; for objects
** being finalized, keep them in keys, but not in values
*/
static int iscleared (global_State *g, const TValue *o) {
  if (!iscollectable(o)) return 0;
  else if (ttisstring(o)) {
    markobject(g, tsvalue(o));  /* strings are 'values', so are never weak */
    return 0;
  }
  else return iswhite(gcvalue(o));
}


/*
** barrier that moves collector forward, that is, mark the white object
** being pointed by a black object. (If in sweep phase, clear the black
** object to white [sweep it] to avoid other barrier calls for this
** same object.)
*/
void luaC_barrier_ (lua_State *L, GCObject *o, GCObject *v) {
  global_State *g = G(L);
  lua_assert(isblack(o) && iswhite(v) && !isdead(g, v) && !isdead(g, o));
  if (keepinvariant(g)) {  /* must keep invariant? */
    if (o->tt == LUA_TPROTO && isold(o)) {
      black2gray(o);
      l_setbit(o->marked, TOUCHEDBIT);
      *getgclist(o) = g->grayagain;
      g->grayagain = o;
    }
    else
      reallymarkobject(g, v);  /* restore invariant */
  }
  else if (g->inbleach)  /* incrementally bleaching oldgen before restartcollection? */
    return;
  else if (!isold(o) && (tofinalize(o) ? (g->tobesweptfin == NULL)
                                       : (g->tobeswept == NULL))) {
    /* non-promoting sweep phase (e.g. fullgc or stopped manual sweep) */
    lua_assert(issweepphase(g));
    makewhite(g, o);  /* mark main obj. as white to avoid other barriers */
  }
  else if (o->tt == LUA_TTABLE || o->tt == LUA_TLCL ||
           o->tt == LUA_TCCL || o->tt == LUA_TPROTO) {
    /* object has gclist: move backward to grayagain so all further writes
       are free and 'o' is re-traversed in the next cycle */
    black2gray(o);
    l_setbit(o->marked, TOUCHEDBIT);
    *getgclist(o) = g->grayagain;
    g->grayagain = o;
  }
  else if (o->tt == LUA_TUSERDATA) {
    /* userdata in old/promoting sweep/callfin/pause phase: link into
       intrusive 'g->remudata' list so repeated writes are O(1) and unbounded */
    if (!testbit(o->marked, TOUCHEDBIT)) {
      l_setbit(o->marked, TOUCHEDBIT);
      gco2u(o)->gclist = g->remudata;
      g->remudata = o;
    }
  }
}


/*
** barrier that moves collector backward, that is, mark the black object
** pointing to a white object as gray again.
*/
void luaC_barrierback_ (lua_State *L, Table *t) {
  global_State *g = G(L);
  lua_assert(isblack(t) && !isdead(g, t));
  if (g->inbleach)
    return;
  if (!keepinvariant(g) && !isold(t) &&
      (tofinalize(t) ? (g->tobesweptfin == NULL) : (g->tobeswept == NULL))) {
    lua_assert(issweepphase(g));
    makewhite(g, t);
    return;
  }
  black2gray(t);  /* make table gray (again) */
  l_setbit(t->marked, TOUCHEDBIT);
  linkgclist(t, g->grayagain);
}


/*
** barrier for assignments to closed upvalues. Because upvalues are
** shared among closures, it is impossible to know the color of all
** closures pointing to it. So, we assume that the object being assigned
** must be marked.
*/
void luaC_upvalbarrier_ (lua_State *L, UpVal *uv) {
  global_State *g = G(L);
  GCObject *o = gcvalue(uv->v);
  lua_assert(!upisopen(uv));  /* ensured by macro luaC_upvalbarrier */
  if (keepinvariant(g)) {
    markobject(g, o);
  }
  else if (!g->inbleach && iswhite(o) && !uv->inrem &&
           (g->oldgc != NULL || g->tobeswept != NULL ||
            g->oldfinobj != NULL || g->tobesweptfin != NULL)) {
    uv->inrem = 1;
    uv->remnext = g->remuv;
    g->remuv = uv;
  }
}


void luaC_fix (lua_State *L, GCObject *o) {
  global_State *g = G(L);
  lua_assert(g->allgc == o);  /* object must be 1st in 'allgc' list! */
  white2gray(o);  /* they will be gray forever */
  g->allgc = o->next;  /* remove object from 'allgc' list */
  o->next = g->fixedgc;  /* link it to 'fixedgc' list */
  g->fixedgc = o;
}


/*
** create a new collectable object (with given type and size) and link
** it to 'allgc' list.
*/
GCObject *luaC_newobj (lua_State *L, int tt, size_t sz) {
  global_State *g = G(L);
  GCObject *o = cast(GCObject *, luaM_newobject(L, novariant(tt), sz));
  o->marked = luaC_white(g);
  o->tt = tt;
  o->next = g->allgc;
  g->allgc = o;
  return o;
}

/* }====================================================== */



/*
** {======================================================
** Mark functions
** =======================================================
*/


/*
** mark an object. Userdata, strings, and closed upvalues are visited
** and turned black here. Other objects are marked gray and added
** to appropriate list to be visited (and turned black) later. (Open
** upvalues are already linked in 'headuv' list.)
*/
static void reallymarkobject (global_State *g, GCObject *o) {
 reentry:
  white2gray(o);
  switch (o->tt) {
    case LUA_TSHRSTR: {
      gray2black(o);
      g->GCmemtrav += sizelstring(gco2ts(o)->shrlen);
      break;
    }
    case LUA_TLNGSTR: {
      gray2black(o);
      g->GCmemtrav += sizelstring(gco2ts(o)->u.lnglen);
      break;
    }
    case LUA_TUSERDATA: {
      TValue uvalue;
      markobjectN(g, gco2u(o)->metatable);  /* mark its metatable */
      gray2black(o);
      g->GCmemtrav += sizeudata(gco2u(o));
      getuservalue(g->mainthread, gco2u(o), &uvalue);
      if (valiswhite(&uvalue)) {  /* markvalue(g, &uvalue); */
        o = gcvalue(&uvalue);
        goto reentry;
      }
      break;
    }
    case LUA_TLCL: {
      linkgclist(gco2lcl(o), g->gray);
      break;
    }
    case LUA_TCCL: {
      linkgclist(gco2ccl(o), g->gray);
      break;
    }
    case LUA_TTABLE: {
      linkgclist(gco2t(o), g->gray);
      break;
    }
    case LUA_TTHREAD: {
      linkgclist(gco2th(o), g->gray);
      break;
    }
    case LUA_TPROTO: {
      linkgclist(gco2p(o), g->gray);
      break;
    }
    default: lua_assert(0); break;
  }
}


/*
** mark metamethods for basic types
*/
static void markmt (global_State *g) {
  int i;
  for (i=0; i < LUA_NUMTAGS; i++)
    markobjectN(g, g->mt[i]);
}


/*
** mark all objects in list of being-finalized
*/
static void markbeingfnz (global_State *g) {
  GCObject *o;
  for (o = g->tobefnz; o != NULL; o = o->next)
    markobject(g, o);
}

static void markoldweak (global_State *g) {
  GCObject *o = g->oldweak;
  g->oldweak = NULL;
  while (o != NULL) {
    GCObject *next = *getgclist(o);
    if (g->oldcount > 0)
      g->oldcount--;
    if (o->tt == LUA_TTABLE)
      gco2t(o)->flags &= cast_byte(~TM_WEAKBIT);
    resetbits(o->marked, bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                         bitmask(TOUCHEDBIT) | bitmask(7));
    if (iswhite(o))
      reallymarkobject(g, o);
    o = next;
  }
}


/*
** Mark all values stored in marked open upvalues from non-marked threads.
** (Values from marked threads were already marked when traversing the
** thread.) Remove from the list threads that no longer have upvalues and
** not-marked threads.
*/
static void remarkupvals (global_State *g) {
  lua_State *thread;
  lua_State **p = &g->twups;
  while ((thread = *p) != NULL) {
    lua_assert(!isblack(thread));  /* threads are never black */
    if (isgray(thread) && thread->openupval != NULL)
      p = &thread->twups;  /* keep marked thread with upvalues in the list */
    else {  /* thread is not marked or without upvalues */
      UpVal *uv;
      *p = thread->twups;  /* remove thread from the list */
      thread->twups = thread;  /* mark that it is out of list */
      for (uv = thread->openupval; uv != NULL; uv = uv->u.open.next) {
        if (uv->u.open.touched || (g->oldgc != NULL && uv->refcount > 0)) {
          markvalue(g, uv->v);  /* remark upvalue's value */
          uv->u.open.touched = 0;
        }
      }
    }
  }
}


/*
** find last 'next' field in list 'p' list (to add elements in its end)
*/
static GCObject **findlast (GCObject **p) {
  while (*p != NULL)
    p = &(*p)->next;
  return p;
}


/*
** Merge all promoted old-generation objects back into 'allgc' and 'finobj'
** as white objects before starting a major (full) collection.
*/
/*
** Start incremental bleaching of promoted old-generation lists ('oldgc' and
** 'oldfinobj') during GCSpause before a major collection. Each singlestep
** bleaches at most GCSWEEPMAX objects and moves them into 'allgc'/'finobj'
** in O(1) without any synchronous full-heap list walk.
*/
static void restartcollection (global_State *g);

static void clearremlists (global_State *g, int mark) {
  while (g->remuv != NULL) {
    UpVal *uv = g->remuv;
    g->remuv = uv->remnext;
    uv->remnext = NULL;
    uv->inrem = 0;
    if (uv->refcount == 0)
      luaM_free(g->mainthread, uv);
    else if (mark)
      markvalue(g, uv->v);
  }
  while (g->remudata != NULL) {
    GCObject *u = g->remudata;
    g->remudata = gco2u(u)->gclist;
    gco2u(u)->gclist = NULL;
    resetbit(u->marked, TOUCHEDBIT);
    if (mark && !isdead(g, u)) {
      TValue uvalue;
      markobjectN(g, gco2u(u)->metatable);
      getuservalue(g->mainthread, gco2u(u), &uvalue);
      markvalue(g, &uvalue);
    }
  }
}


static void startbleach (global_State *g) {
  int white = luaC_white(g);
  GCObject *curr;
  GCObject **p;
  g->gray = NULL;
  g->grayagain = NULL;
  g->grayatomic = NULL;
  g->oldweak = NULL;
  clearremlists(g, 0);
  for (p = &g->finobj; *p != NULL; p = &(*p)->next) {
    curr = *p;
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
  }
  g->fintail = p;
  makewhite(g, g->mainthread);
  resetbits(g->mainthread->marked, bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                                   bitmask(TOUCHEDBIT) | bitmask(7));
  g->oldcount = 0;
  g->needmajor = 0;
  g->ismajor = 1;
  g->minorcycles = 0;
  g->inbleach = 1;
  g->drainedgray = 0;
}


static lu_mem bleachstep (global_State *g) {
  int white = luaC_white(g);
  lu_mem count = GCSWEEPMAX;
  while (g->oldgc != NULL && count > 0) {
    GCObject *curr = g->oldgc;
    g->oldgc = curr->next;
    if (g->oldgc != NULL)
      l_prefetch(g->oldgc);
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
    curr->next = g->allgc;
    g->allgc = curr;
    count--;
  }
  while (g->oldfinobj != NULL && count > 0) {
    GCObject *curr = g->oldfinobj;
    g->oldfinobj = curr->next;
    if (g->oldfinobj != NULL)
      l_prefetch(g->oldfinobj);
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
    curr->next = NULL;
    *g->fintail = curr;
    g->fintail = &curr->next;
    count--;
  }
  if (g->oldgc != NULL || g->oldfinobj != NULL)
    return (g->GCestimate > 4 * 1024 * 1024 && g->GCdebt > GCSTEPSIZE) ? (GCSWEEPMAX * GCSWEEPCOST * 4)
                                             : (GCSWEEPMAX * GCSWEEPCOST);
  g->fintail = NULL;
  g->inbleach = 0;
  g->GCmemtrav = g->strt.size * sizeof(GCObject*);
  restartcollection(g);
  g->gcstate = GCSpropagate;
  return g->GCmemtrav;
}


static void mergeoldgen (global_State *g) {
  int white = luaC_white(g);
  GCObject **p;
  g->inbleach = 0;
  g->drainedgray = 0;
  g->fintail = NULL;
  g->gray = NULL;
  g->grayagain = NULL;
  g->grayatomic = NULL;
  g->oldweak = NULL;
  clearremlists(g, 0);
  for (p = &g->allgc; *p != NULL; p = &(*p)->next) {
    GCObject *curr = *p;
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
  }
  for (p = &g->oldgc; *p != NULL; p = &(*p)->next) {
    GCObject *curr = *p;
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
  }
  *p = g->allgc;
  g->allgc = g->oldgc;
  g->oldgc = NULL;
  for (p = &g->finobj; *p != NULL; p = &(*p)->next) {
    GCObject *curr = *p;
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
  }
  for (p = &g->oldfinobj; *p != NULL; p = &(*p)->next) {
    GCObject *curr = *p;
    if (curr->tt == LUA_TTABLE)
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
    curr->marked = cast_byte((curr->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                   bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                   bitmask(TOUCHEDBIT) | bitmask(7))) | white);
  }
  if (g->oldfinobj != NULL) {
    *findlast(&g->finobj) = g->oldfinobj;
    g->oldfinobj = NULL;
  }
  makewhite(g, g->mainthread);
  resetbits(g->mainthread->marked, bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                                   bitmask(TOUCHEDBIT) | bitmask(7));
  g->oldcount = 0;
  g->needmajor = 0;
}


/*
** mark root set and reset all gray lists, to start a new collection.
** Note: objects placed in 'g->grayagain' by write barriers during sweep/pause
** remain in 'g->grayagain' (still gray) during 'GCSpropagate' so repeated
** mutations to hot old tables during 'GCSpropagate' incur zero barrier work
** and each hot table is traversed only once near the end of 'GCSpropagate'.
*/
static void restartcollection (global_State *g) {
  g->gray = NULL;
  g->grayatomic = NULL;
  g->drainedgray = 0;
  g->weak = g->allweak = g->ephemeron = NULL;
  makewhite(g, g->mainthread);
  markobject(g, g->mainthread);
  markvalue(g, &g->l_registry);
  markmt(g);
  markbeingfnz(g);  /* mark any finalizing object left from previous cycle */
  /* mark surviving threads and weak tables from previous minor cycle */
  markoldweak(g);
  /* mark remembered values from barriers outside mark phase */
  clearremlists(g, 1);
}

/* }====================================================== */


/*
** {======================================================
** Traverse functions
** =======================================================
*/

/*
** Traverse a table with weak values and link it to proper list. During
** propagate phase, keep it in 'grayagain' list, to be revisited in the
** atomic phase. In the atomic phase, if table has any white value,
** put it in 'weak' list, to be cleared.
*/
static void traverseweakvalue (global_State *g, Table *h) {
  Node *n, *limit = gnodelast(h);
  /* if there is array part, assume it may have white values (it is not
     worth traversing it now just to check) */
  int hasclears = (h->sizearray > 0);
  for (n = gnode(h, 0); n < limit; n++) {  /* traverse hash part */
    checkdeadkey(n);
    if (ttisnil(gval(n)))  /* entry is empty? */
      removeentry(n);  /* remove it */
    else {
      lua_assert(!ttisnil(gkey(n)));
      markvalue(g, gkey(n));  /* mark key */
      if (!hasclears && iscleared(g, gval(n)))  /* is there a white value? */
        hasclears = 1;  /* table will have to be cleared */
    }
  }
  if (g->gcstate == GCSpropagate)
    linkgclist(h, g->grayatomic);  /* must retraverse it in atomic phase */
  else if (hasclears)
    linkgclist(h, g->weak);  /* has to be cleared later */
  else if (isold(h)) {
    gray2black(h);
    h->flags &= cast_byte(~TM_WEAKBIT);
    resetbits(h->marked, bitmask(SURVIVALBIT) | bitmask(7));
  }
}


/*
** Traverse an ephemeron table and link it to proper list. Returns true
** iff any object was marked during this traversal (which implies that
** convergence has to continue). During propagation phase, keep table
** in 'grayagain' list, to be visited again in the atomic phase. In
** the atomic phase, if table has any white->white entry, it has to
** be revisited during ephemeron convergence (as that key may turn
** black). Otherwise, if it has any white key, table has to be cleared
** (in the atomic phase).
*/
static int traverseephemeron (global_State *g, Table *h) {
  int marked = 0;  /* true if an object is marked in this traversal */
  int hasclears = 0;  /* true if table has white keys */
  int hasww = 0;  /* true if table has entry "white-key -> white-value" */
  Node *n, *limit = gnodelast(h);
  unsigned int i;
  /* traverse array part */
  for (i = 0; i < h->sizearray; i++) {
    if (valiswhite(&h->array[i])) {
      marked = 1;
      reallymarkobject(g, gcvalue(&h->array[i]));
    }
  }
  /* traverse hash part */
  for (n = gnode(h, 0); n < limit; n++) {
    checkdeadkey(n);
    if (ttisnil(gval(n)))  /* entry is empty? */
      removeentry(n);  /* remove it */
    else if (iscleared(g, gkey(n))) {  /* key is not marked (yet)? */
      hasclears = 1;  /* table must be cleared */
      if (valiswhite(gval(n)))  /* value not marked yet? */
        hasww = 1;  /* white-white entry */
    }
    else if (valiswhite(gval(n))) {  /* value not marked yet? */
      marked = 1;
      reallymarkobject(g, gcvalue(gval(n)));  /* mark it now */
    }
  }
  /* link table into proper list */
  if (g->gcstate == GCSpropagate)
    linkgclist(h, g->grayatomic);  /* must retraverse it in atomic phase */
  else if (hasww)  /* table has white->white entries? */
    linkgclist(h, g->ephemeron);  /* have to propagate again */
  else if (hasclears)  /* table has white keys? */
    linkgclist(h, g->allweak);  /* may have to clean white keys */
  else if (isold(h)) {
    gray2black(h);
    h->flags &= cast_byte(~TM_WEAKBIT);
    resetbits(h->marked, bitmask(SURVIVALBIT) | bitmask(7));
  }
  return marked;
}


static void traversestrongtable (global_State *g, Table *h) {
  Node *n, *limit = gnodelast(h);
  unsigned int i;
  for (i = 0; i < h->sizearray; i++)  /* traverse array part */
    markvalue(g, &h->array[i]);
  for (n = gnode(h, 0); n < limit; n++) {  /* traverse hash part */
    checkdeadkey(n);
    if (ttisnil(gval(n)))  /* entry is empty? */
      removeentry(n);  /* remove it */
    else {
      lua_assert(!ttisnil(gkey(n)));
      markvalue(g, gkey(n));  /* mark key */
      markvalue(g, gval(n));  /* mark value */
    }
  }
}


static lu_mem traversetable (global_State *g, Table *h) {
  const char *weakkey, *weakvalue;
  const TValue *mode = gfasttm(g, h->metatable, TM_MODE);
  markobjectN(g, h->metatable);
  if (mode && ttisstring(mode) &&  /* is there a weak mode? */
      ((weakkey = strchr(svalue(mode), 'k')),
       (weakvalue = strchr(svalue(mode), 'v')),
       (weakkey || weakvalue))) {  /* is really weak? */
    black2gray(h);  /* keep table gray */
    h->flags |= cast_byte(TM_WEAKBIT);
    if (isold(h))
      g->needmajor = 1;
    if (!weakkey)  /* strong keys? */
      traverseweakvalue(g, h);
    else if (!weakvalue)  /* strong values? */
      traverseephemeron(g, h);
    else if (g->gcstate == GCSpropagate)  /* all weak in propagate? */
      linkgclist(h, g->grayatomic);  /* must retraverse it in atomic phase */
    else  /* all weak in atomic */
      linkgclist(h, g->allweak);  /* nothing to traverse now */
  }
  else {  /* not weak */
    h->flags &= cast_byte(~TM_WEAKBIT);
    traversestrongtable(g, h);
  }
  return sizeof(Table) + sizeof(TValue) * h->sizearray +
                         sizeof(Node) * cast(size_t, allocsizenode(h));
}


/*
** Traverse a prototype. (While a prototype is being build, its
** arrays can be larger than needed; the extra slots are filled with
** NULL, so the use of 'markobjectN')
*/
static int traverseproto (global_State *g, Proto *f) {
  int i;
  if (f->cache && (iswhite(f->cache) || isold(f)))
    f->cache = NULL;  /* allow cache to be collected */
  markobjectN(g, f->source);
  for (i = 0; i < f->sizek; i++)  /* mark literals */
    markvalue(g, &f->k[i]);
  for (i = 0; i < f->sizeupvalues; i++)  /* mark upvalue names */
    markobjectN(g, f->upvalues[i].name);
  for (i = 0; i < f->sizep; i++)  /* mark nested protos */
    markobjectN(g, f->p[i]);
  for (i = 0; i < f->sizelocvars; i++)  /* mark local-variable names */
    markobjectN(g, f->locvars[i].varname);
  return sizeof(Proto) + sizeof(Instruction) * f->sizecode +
                         sizeof(Proto *) * f->sizep +
                         sizeof(TValue) * f->sizek +
                         sizeof(int) * f->sizelineinfo +
                         sizeof(LocVar) * f->sizelocvars +
                         sizeof(Upvaldesc) * f->sizeupvalues;
}


static lu_mem traverseCclosure (global_State *g, CClosure *cl) {
  int i;
  for (i = 0; i < cl->nupvalues; i++)  /* mark its upvalues */
    markvalue(g, &cl->upvalue[i]);
  return sizeCclosure(cl->nupvalues);
}

/*
** open upvalues point to values in a thread, so those values should
** be marked when the thread is traversed except in the atomic phase
** (because then the value cannot be changed by the thread and the
** thread may not be traversed again)
*/
static lu_mem traverseLclosure (global_State *g, LClosure *cl) {
  int i;
  markobjectN(g, cl->p);  /* mark its prototype */
  for (i = 0; i < cl->nupvalues; i++) {  /* mark its upvalues */
    UpVal *uv = cl->upvals[i];
    if (uv != NULL) {
      if (upisopen(uv) && g->gcstate != GCSinsideatomic)
        uv->u.open.touched = 1;  /* can be marked in 'remarkupvals' */
      else
        markvalue(g, uv->v);
    }
  }
  return sizeLclosure(cl->nupvalues);
}


static lu_mem traversethread (global_State *g, lua_State *th) {
  StkId o = th->stack;
  if (o == NULL)
    return 1;  /* stack not completely built yet */
  lua_assert(g->gcstate == GCSinsideatomic ||
             th->openupval == NULL || isintwups(th));
  for (; o < th->top; o++)  /* mark live elements in the stack */
    markvalue(g, o);
  if (g->gcstate == GCSinsideatomic) {  /* final traversal? */
    StkId lim = th->stack + th->stacksize;  /* real end of stack */
    for (; o < lim; o++)  /* clear not-marked stack slice */
      setnilvalue(o);
    /* 'remarkupvals' may have removed thread from 'twups' list */
    if (!isintwups(th) && th->openupval != NULL) {
      th->twups = g->twups;  /* link it back to the list */
      g->twups = th;
    }
  }
  else if (g->gckind != KGC_EMERGENCY)
    luaD_shrinkstack(th); /* do not change stack in emergency cycle */
  return (sizeof(lua_State) + sizeof(TValue) * th->stacksize +
          sizeof(CallInfo) * th->nci);
}


/*
** traverse one gray object, turning it to black (except for threads,
** which are always gray).
*/
static void propagatemark (global_State *g) {
  lu_mem size;
  GCObject *o = g->gray;
  lua_assert(isgray(o));
  resetbits(o->marked, bitmask(TOUCHEDBIT) | bitmask(7));
  gray2black(o);
  switch (o->tt) {
    case LUA_TTABLE: {
      Table *h = gco2t(o);
      g->gray = h->gclist;  /* remove from 'gray' list */
      size = traversetable(g, h);
      break;
    }
    case LUA_TLCL: {
      LClosure *cl = gco2lcl(o);
      g->gray = cl->gclist;  /* remove from 'gray' list */
      size = traverseLclosure(g, cl);
      break;
    }
    case LUA_TCCL: {
      CClosure *cl = gco2ccl(o);
      g->gray = cl->gclist;  /* remove from 'gray' list */
      size = traverseCclosure(g, cl);
      break;
    }
    case LUA_TTHREAD: {
      lua_State *th = gco2th(o);
      g->gray = th->gclist;  /* remove from 'gray' list */
      if (g->gcstate != GCSinsideatomic)
        linkgclist(th, g->grayatomic);  /* insert into 'grayatomic' list */
      black2gray(o);
      size = traversethread(g, th);
      break;
    }
    case LUA_TPROTO: {
      Proto *p = gco2p(o);
      g->gray = p->gclist;  /* remove from 'gray' list */
      size = traverseproto(g, p);
      break;
    }
    default: lua_assert(0); return;
  }
  if (g->GCestimate > 4 * 1024 * 1024 && g->GCdebt > GCSTEPSIZE)
    size += 256;
  g->GCmemtrav += size;
}


static void propagateall (global_State *g) {
  while (g->gray) propagatemark(g);
}


static void convergeephemerons (global_State *g) {
  int changed;
  do {
    GCObject *w;
    GCObject *next = g->ephemeron;  /* get ephemeron list */
    g->ephemeron = NULL;  /* tables may return to this list when traversed */
    changed = 0;
    while ((w = next) != NULL) {
      next = gco2t(w)->gclist;
      if (traverseephemeron(g, gco2t(w))) {  /* traverse marked some value? */
        propagateall(g);  /* propagate changes */
        changed = 1;  /* will have to revisit all ephemeron tables */
      }
    }
  } while (changed);
}

/* }====================================================== */


/*
** {======================================================
** Sweep Functions
** =======================================================
*/


/*
** clear entries with unmarked keys from all weaktables in list 'l' up
** to element 'f'
*/
static void clearkeys (global_State *g, GCObject *l, GCObject *f) {
  for (; l != f; l = gco2t(l)->gclist) {
    Table *h = gco2t(l);
    Node *n, *limit = gnodelast(h);
    for (n = gnode(h, 0); n < limit; n++) {
      if (!ttisnil(gval(n)) && (iscleared(g, gkey(n)))) {
        setnilvalue(gval(n));  /* remove value ... */
        removeentry(n);  /* and remove entry from table */
      }
    }
  }
}


/*
** clear entries with unmarked values from all weaktables in list 'l' up
** to element 'f'
*/
static void clearvalues (global_State *g, GCObject *l, GCObject *f) {
  for (; l != f; l = gco2t(l)->gclist) {
    Table *h = gco2t(l);
    Node *n, *limit = gnodelast(h);
    unsigned int i;
    for (i = 0; i < h->sizearray; i++) {
      TValue *o = &h->array[i];
      if (iscleared(g, o))  /* value was collected? */
        setnilvalue(o);  /* remove value */
    }
    for (n = gnode(h, 0); n < limit; n++) {
      if (!ttisnil(gval(n)) && iscleared(g, gval(n))) {
        setnilvalue(gval(n));  /* remove value ... */
        removeentry(n);  /* and remove entry from table */
      }
    }
  }
}


void luaC_upvdeccount (lua_State *L, UpVal *uv) {
  lua_assert(uv->refcount > 0);
  uv->refcount--;
  if (uv->refcount == 0 && !upisopen(uv)) {
    if (uv->inrem)
      setnilvalue(uv->v);
    else
      luaM_free(L, uv);
  }
}


static void freeLclosure (lua_State *L, LClosure *cl) {
  int i;
  for (i = 0; i < cl->nupvalues; i++) {
    UpVal *uv = cl->upvals[i];
    if (uv)
      luaC_upvdeccount(L, uv);
  }
  luaM_freemem(L, cl, sizeLclosure(cl->nupvalues));
}


static void freeobj (lua_State *L, GCObject *o) {
  switch (o->tt) {
    case LUA_TPROTO: luaF_freeproto(L, gco2p(o)); break;
    case LUA_TLCL: {
      freeLclosure(L, gco2lcl(o));
      break;
    }
    case LUA_TCCL: {
      luaM_freemem(L, o, sizeCclosure(gco2ccl(o)->nupvalues));
      break;
    }
    case LUA_TTABLE: luaH_free(L, gco2t(o)); break;
    case LUA_TTHREAD: luaE_freethread(L, gco2th(o)); break;
    case LUA_TUSERDATA: luaM_freemem(L, o, sizeudata(gco2u(o))); break;
    case LUA_TSHRSTR:
      luaS_remove(L, gco2ts(o));  /* remove it from hash table */
      luaM_freemem(L, o, sizelstring(gco2ts(o)->shrlen));
      break;
    case LUA_TLNGSTR: {
      luaM_freemem(L, o, sizelstring(gco2ts(o)->u.lnglen));
      break;
    }
    default: lua_assert(0);
  }
}


#define sweepwholelist(L,p)	sweeplist(L,p,MAX_LUMEM)
static GCObject **sweeplist (lua_State *L, GCObject **p, lu_mem count);


/*
** sweep at most 'count' elements from a list of GCObjects erasing dead
** objects, where a dead object is one marked with the old (non current)
** white; change all non-dead objects back to white, preparing for next
** collection cycle. Return where to continue the traversal or NULL if
** list is finished.
*/
static GCObject **sweeplist (lua_State *L, GCObject **p, lu_mem count) {
  global_State *g = G(L);
  int ow = otherwhite(g);
  int white = luaC_white(g);  /* current white */
  while (*p != NULL && count-- > 0) {
    GCObject *curr = *p;
    int marked = curr->marked;
    if (curr->next != NULL)
      l_prefetch(curr->next);
    if (isdeadm(ow, marked)) {  /* is 'curr' dead? */
      *p = curr->next;  /* remove 'curr' from list */
      freeobj(L, curr);  /* erase 'curr' */
    }
    else {  /* change mark to 'white' */
      if (curr->tt == LUA_TTABLE)
        gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
      curr->marked = cast_byte((marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                     bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                     bitmask(TOUCHEDBIT) | bitmask(7))) | white);
      p = &curr->next;  /* go to next element */
    }
  }
  return (*p == NULL) ? NULL : p;
}


/*
** Sweep detached young objects ('tobeswept') in incremental mode:
** erase dead objects and promote surviving objects into 'oldgc' (with
** BLACKBIT | OLDBIT so subsequent minor cycles skip them in both
** propagatemark and sweeplist). Surviving threads and weak tables stay
** in 'allgc' and are linked into 'oldweak' via 'gclist' to be marked
** at the start of the next minor cycle.
*/
static GCObject **sweeptobeswept (lua_State *L, GCObject **p, lu_mem count) {
  global_State *g = G(L);
  int ow = otherwhite(g);
  int white = luaC_white(g);
  while (*p != NULL && count-- > 0) {
    GCObject *curr = *p;
    int marked = curr->marked;
    *p = curr->next;
    if (*p != NULL)
      l_prefetch(*p);
    if (isdeadm(ow, marked)) {  /* is 'curr' dead? */
      freeobj(L, curr);  /* erase 'curr' */
    }
    else if (iswhite(curr)) {
      /* 'makewhite' was called by barrier during sweep; keep as young white */
      if (curr->tt == LUA_TTABLE)
        gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
      curr->marked = cast_byte((marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                     bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                     bitmask(TOUCHEDBIT) | bitmask(7))) | white);
      curr->next = g->allgc;
      g->allgc = curr;
    }
    else if (curr->tt == LUA_TTHREAD) {
      curr->marked = cast_byte((marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                     bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                     bitmask(TOUCHEDBIT) | bitmask(7))) | white);
      curr->next = g->allgc;
      g->allgc = curr;
      linkgclist(gco2th(curr), g->oldweak);
      g->oldcount++;
    }
    else if (curr->tt == LUA_TTABLE && (gco2t(curr)->flags & TM_WEAKBIT)) {
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
      curr->marked = cast_byte((marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                     bitmask(OLDBIT) | bitmask(SURVIVALBIT) |
                     bitmask(TOUCHEDBIT) | bitmask(7))) | white);
      curr->next = g->allgc;
      g->allgc = curr;
      linkgclist(gco2t(curr), g->oldweak);
      g->oldcount++;
    }

    else {
      if (curr->tt == LUA_TPROTO) {
        Proto *f = gco2p(curr);
        if (f->cache && !isblack(f->cache))
          f->cache = NULL;
      }
      if (testbit(marked, TOUCHEDBIT) && curr->tt != LUA_TUSERDATA) {
        curr->marked = cast_byte((marked & ~(WHITEBITS | bitmask(BLACKBIT) |
                       bitmask(SURVIVALBIT) | bitmask(7))) |
                       bitmask(OLDBIT) | bitmask(TOUCHEDBIT));
      }
      else if (testbit(marked, TOUCHEDBIT)) {
        curr->marked = cast_byte((marked & ~(WHITEBITS |
                       bitmask(SURVIVALBIT) | bitmask(7))) |
                       bitmask(BLACKBIT) | bitmask(OLDBIT) | bitmask(TOUCHEDBIT));
      }
      else {
        curr->marked = cast_byte((marked & ~(WHITEBITS | bitmask(SURVIVALBIT) |
                       bitmask(TOUCHEDBIT) | bitmask(7))) |
                       bitmask(BLACKBIT) | bitmask(OLDBIT));
      }
      curr->next = g->oldgc;
      g->oldgc = curr;
      g->oldcount++;
    }
  }
  return (*p == NULL) ? NULL : p;
}


/*
** Sweep detached surviving finalizable objects ('tobesweptfin') in place,
** promoting them to BLACKBIT | OLDBIT while preserving their creation order.
*/
static GCObject **sweepfinobj (global_State *g, GCObject **p, lu_mem count) {
  while (*p != NULL && count-- > 0) {
    GCObject *curr = *p;
    int marked = curr->marked;
    lua_assert(!isdead(g, curr));
    if (curr->tt == LUA_TTABLE && (gco2t(curr)->flags & TM_WEAKBIT)) {
      gco2t(curr)->flags &= cast_byte(~TM_WEAKBIT);
      g->needmajor = 1;
    }
    if (testbit(marked, TOUCHEDBIT) && curr->tt != LUA_TUSERDATA) {
      curr->marked = cast_byte((marked & ~(WHITEBITS | bitmask(BLACKBIT) |
                     bitmask(SURVIVALBIT) | bitmask(7))) |
                     bitmask(OLDBIT) | bitmask(TOUCHEDBIT));
    }
    else if (testbit(marked, TOUCHEDBIT)) {
      curr->marked = cast_byte((marked & ~(WHITEBITS |
                     bitmask(SURVIVALBIT) | bitmask(7))) |
                     bitmask(BLACKBIT) | bitmask(OLDBIT) | bitmask(TOUCHEDBIT));
    }
    else {
      curr->marked = cast_byte((marked & ~(WHITEBITS | bitmask(SURVIVALBIT) |
                     bitmask(TOUCHEDBIT) | bitmask(7))) |
                     bitmask(BLACKBIT) | bitmask(OLDBIT));
    }
    g->oldcount++;
    p = &curr->next;
  }
  return (*p == NULL) ? NULL : p;
}


/*
** sweep a list until a live object (or end of list)
*/
static GCObject **sweeptolive (lua_State *L, GCObject **p) {
  GCObject **old = p;
  do {
    p = sweeplist(L, p, 1);
  } while (p == old);
  return p;
}

/* }====================================================== */


/*
** {======================================================
** Finalization
** =======================================================
*/

/*
** If possible, shrink string table
*/
static void checkSizes (lua_State *L, global_State *g) {
  if (g->gckind != KGC_EMERGENCY) {
    l_mem olddebt = g->GCdebt;
    if (g->strt.nuse < g->strt.size / 4)  /* string table too big? */
      luaS_resize(L, g->strt.size / 2);  /* shrink it a little */
    g->GCestimate += g->GCdebt - olddebt;  /* update estimate */
  }
}


static GCObject *udata2finalize (global_State *g) {
  GCObject *o = g->tobefnz;  /* get first element */
  lua_assert(tofinalize(o));
  g->tobefnz = o->next;  /* remove it from 'tobefnz' list */
  if (g->sweepgc == &o->next)
    g->sweepgc = &g->tobefnz;
  o->next = g->allgc;  /* return it to 'allgc' list */
  g->allgc = o;
  if (o->tt == LUA_TTABLE)
    gco2t(o)->flags &= cast_byte(~TM_WEAKBIT);
  resetbits(o->marked, bitmask(FINALIZEDBIT) | bitmask(OLDBIT) |
                       bitmask(SURVIVALBIT) | bitmask(TOUCHEDBIT) | bitmask(7));
  if (issweepphase(g))
    makewhite(g, o);  /* "sweep" object */
  return o;
}


static void dothecall (lua_State *L, void *ud) {
  UNUSED(ud);
  luaD_callnoyield(L, L->top - 2, 0);
}


static void GCTM (lua_State *L, int propagateerrors) {
  global_State *g = G(L);
  const TValue *tm;
  TValue v;
  setgcovalue(L, &v, udata2finalize(g));
  tm = luaT_gettmbyobj(L, &v, TM_GC);
  if (tm != NULL && ttisfunction(tm)) {  /* is there a finalizer? */
    int status;
    lu_byte oldah = L->allowhook;
    int running  = g->gcrunning;
    L->allowhook = 0;  /* stop debug hooks during GC metamethod */
    g->gcrunning = 0;  /* avoid GC steps */
    setobj2s(L, L->top, tm);  /* push finalizer... */
    setobj2s(L, L->top + 1, &v);  /* ... and its argument */
    L->top += 2;  /* and (next line) call the finalizer */
    L->ci->callstatus |= CIST_FIN;  /* will run a finalizer */
    status = luaD_pcall(L, dothecall, NULL, savestack(L, L->top - 2), 0);
    L->ci->callstatus &= ~CIST_FIN;  /* not running a finalizer anymore */
    L->allowhook = oldah;  /* restore hooks */
    g->gcrunning = running;  /* restore state */
    if (status != LUA_OK && propagateerrors) {  /* error while running __gc? */
      if (status == LUA_ERRRUN) {  /* is there an error object? */
        const char *msg = (ttisstring(L->top - 1))
                            ? svalue(L->top - 1)
                            : "no message";
        luaO_pushfstring(L, "error in __gc metamethod (%s)", msg);
        status = LUA_ERRGCMM;  /* error in __gc metamethod */
      }
      luaD_throw(L, status);  /* re-throw error */
    }
  }
}


/*
** call a few (up to 'g->gcfinnum') finalizers
*/
static int runafewfinalizers (lua_State *L) {
  global_State *g = G(L);
  unsigned int i;
  lua_assert(!g->tobefnz || g->gcfinnum > 0);
  for (i = 0; g->tobefnz && i < g->gcfinnum; i++)
    GCTM(L, 1);  /* call one finalizer */
  g->gcfinnum = (!g->tobefnz) ? 0  /* nothing more to finalize? */
                    : g->gcfinnum * 2;  /* else call a few more next time */
  return i;
}


/*
** call all pending finalizers
*/
static void callallpendingfinalizers (lua_State *L) {
  global_State *g = G(L);
  while (g->tobefnz)
    GCTM(L, 0);
}


/*
** move all unreachable objects (or 'all' objects) that need
** finalization from list 'finobj' to list 'tobefnz' (to be finalized)
*/
static void separatetobefnz (global_State *g, int all) {
  GCObject *curr;
  GCObject **p = &g->finobj;
  GCObject **lastnext = findlast(&g->tobefnz);
  while ((curr = *p) != NULL) {  /* traverse all finalizable objects */
    lua_assert(tofinalize(curr));
    if (!(iswhite(curr) || all))  /* not being collected? */
      p = &curr->next;  /* don't bother with it */
    else {
      *p = curr->next;  /* remove 'curr' from 'finobj' list */
      curr->next = *lastnext;  /* link at the end of 'tobefnz' list */
      *lastnext = curr;
      lastnext = &curr->next;
    }
  }
}


/*
** if object 'o' has a finalizer, remove it from 'allgc' (or 'oldgc' /
** 'tobeswept') list and link it in 'finobj' (or 'oldfinobj') list.
*/
void luaC_checkfinalizer (lua_State *L, GCObject *o, Table *mt) {
  global_State *g = G(L);
  if (tofinalize(o) ||                 /* obj. is already marked... */
      gfasttm(g, mt, TM_GC) == NULL)   /* or has no finalizer? */
    return;  /* nothing to be done */
  else {  /* move 'o' to 'finobj' list */
    GCObject **p;
    if (isold(o)) {
      for (p = &g->oldgc; *p != NULL && *p != o; p = &(*p)->next) { /* empty */ }
      if (*p == o) {
        *p = o->next;
        if (g->oldcount > 0)
          g->oldcount--;
        if (keepinvariant(g)) {
          resetbit(o->marked, OLDBIT);
          l_setbit(o->marked, FINALIZEDBIT);
          o->next = g->finobj;
          g->finobj = o;
          g->needmajor = 1;
        }
        else {
          if (testbit(o->marked, TOUCHEDBIT)) {
            GCObject **pg;
            if (o->tt == LUA_TUSERDATA) {
              for (pg = &g->remudata; *pg != NULL && *pg != o; pg = &gco2u(*pg)->gclist) { /* empty */ }
              if (*pg == o) *pg = gco2u(o)->gclist;
            }
            else {
              for (pg = &g->grayagain; *pg != NULL && *pg != o; pg = getgclist(*pg)) { /* empty */ }
              if (*pg == o) *pg = *getgclist(o);
            }
          }
          if (o->tt == LUA_TTABLE)
            gco2t(o)->flags &= cast_byte(~TM_WEAKBIT);
          if (g->inbleach) {
            o->marked = cast_byte((o->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                        bitmask(OLDBIT) | bitmask(SURVIVALBIT) | bitmask(TOUCHEDBIT) |
                        bitmask(7))) | luaC_white(g) | bitmask(FINALIZEDBIT));
            if (g->finobj == NULL)
              g->fintail = &o->next;
            o->next = g->finobj;
            g->finobj = o;
          }
          else if (g->tobesweptfin != NULL) {
            o->marked = cast_byte((o->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                        bitmask(OLDBIT) | bitmask(SURVIVALBIT) | bitmask(TOUCHEDBIT) |
                        bitmask(7))) | luaC_white(g) | bitmask(FINALIZEDBIT));
            o->next = g->finobj;
            g->finobj = o;
            g->needmajor = 1;
          }
          else {
            o->marked = cast_byte((o->marked & ~(WHITEBITS | bitmask(SURVIVALBIT) |
                        bitmask(TOUCHEDBIT) | bitmask(7))) |
                        bitmask(BLACKBIT) | bitmask(OLDBIT) | bitmask(FINALIZEDBIT));
            o->next = g->oldfinobj;
            g->oldfinobj = o;
            g->oldcount++;
            g->needmajor = 1;
          }
        }
        return;
      }
    }
    for (p = &g->allgc; *p != NULL && *p != o; p = &(*p)->next) { /* empty */ }
    if (*p == o) {
      if (issweepphase(g) && g->tobeswept == NULL) {
        makewhite(g, o);  /* "sweep" object 'o' */
        if (g->sweepgc == &o->next)  /* should not remove 'sweepgc' object */
          g->sweepgc = sweeptolive(L, g->sweepgc);  /* change 'sweepgc' */
      }
      *p = o->next;  /* remove 'o' from 'allgc' list */
      if (g->inbleach && g->finobj == NULL)
        g->fintail = &o->next;
      o->next = g->finobj;  /* link it in 'finobj' list */
      g->finobj = o;
      l_setbit(o->marked, FINALIZEDBIT);  /* mark it as such */
    }
    else {
      /* 'o' is in 'tobeswept' waiting to be promoted */
      for (p = &g->tobeswept; *p != o; p = &(*p)->next) { /* empty */ }
      *p = o->next;
      if (testbit(o->marked, TOUCHEDBIT)) {
        GCObject **pg;
        if (o->tt == LUA_TUSERDATA) {
          for (pg = &g->remudata; *pg != NULL && *pg != o; pg = &gco2u(*pg)->gclist) { /* empty */ }
          if (*pg == o) *pg = gco2u(o)->gclist;
        }
        else {
          for (pg = &g->grayagain; *pg != NULL && *pg != o; pg = getgclist(*pg)) { /* empty */ }
          if (*pg == o) *pg = *getgclist(o);
        }
      }
      if (o->tt == LUA_TTABLE)
        gco2t(o)->flags &= cast_byte(~TM_WEAKBIT);
      o->marked = cast_byte((o->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                  bitmask(OLDBIT) | bitmask(SURVIVALBIT) | bitmask(TOUCHEDBIT) |
                  bitmask(7))) | luaC_white(g) | bitmask(FINALIZEDBIT));
      o->next = g->finobj;
      g->finobj = o;
      g->needmajor = 1;
    }
  }
}

/* }====================================================== */



/*
** {======================================================
** GC control
** =======================================================
*/


/*
** Set a reasonable "time" to wait before starting a new GC cycle; cycle
** will start when memory use hits threshold. (Division by 'estimate'
** should be OK: it cannot be zero (because Lua cannot even start with
** less than PAUSEADJ bytes).
*/
static void setpause (global_State *g) {
  l_mem threshold, debt;
  l_mem estimate = g->GCestimate / PAUSEADJ;  /* adjust 'estimate' */
  lua_assert(estimate > 0);
  threshold = (g->gcpause < MAX_LMEM / estimate)  /* overflow? */
            ? estimate * g->gcpause  /* no overflow */
            : MAX_LMEM;  /* overflow; truncate to maximum */
  debt = gettotalbytes(g) - threshold;
  /* When old generation is populated, ensure a reasonable minimum nursery
     budget even when gcpause <= 100 so minor cycles don't spin with 0 debt. */
  if (g->oldgc != NULL) {
    l_mem minpause = cast(l_mem, g->GCestimate >> 4);
    if (minpause > cast(l_mem, GCSTEPSIZE * 4) && debt > -minpause)
      debt = -minpause;
    if (!g->needmajor && g->GCestimate > 4 * 1024 * 1024) {
      l_mem maxpause = cast(l_mem, g->GCestimate >> 3);
      if (debt < -maxpause)
        debt = -maxpause;
    }
  }
  luaE_setdebt(g, debt);
}


/*
** Enter first sweep phase.
** The call to 'sweeplist' tries to make pointer point to an object
** inside the list (instead of to the header), so that the real sweep do
** not need to skip objects created between "now" and the start of the
** real sweep.
*/
static void entersweep (lua_State *L) {
  global_State *g = G(L);
  GCObject *o;
  int white = luaC_white(g);
  g->gcstate = GCSswpallgc;
  lua_assert(g->sweepgc == NULL);
  for (o = g->tobefnz; o != NULL; o = o->next) {
    if (o->tt == LUA_TTABLE)
      gco2t(o)->flags &= cast_byte(~TM_WEAKBIT);
    o->marked = cast_byte((o->marked & ~(bitmask(BLACKBIT) | WHITEBITS |
                bitmask(OLDBIT) | bitmask(SURVIVALBIT) | bitmask(TOUCHEDBIT) |
                bitmask(7))) | white);
  }
  if (!g->infullgc && g->gcrunning) {
    g->tobeswept = g->allgc;
    g->allgc = NULL;
    g->tobesweptfin = g->finobj;
    g->finobj = NULL;
    g->sweepgc = sweeptobeswept(L, &g->tobeswept, 1);
  }
  else {
    g->sweepgc = sweeplist(L, &g->allgc, 1);
  }
}


void luaC_freeallobjects (lua_State *L) {
  global_State *g = G(L);
  if (g->tobeswept != NULL) {
    *findlast(&g->tobeswept) = g->allgc;
    g->allgc = g->tobeswept;
    g->tobeswept = NULL;
  }
  if (g->tobesweptfin != NULL) {
    *findlast(&g->tobesweptfin) = g->oldfinobj;
    g->oldfinobj = g->tobesweptfin;
    g->tobesweptfin = NULL;
  }
  g->sweepgc = NULL;
  g->infullgc = 1;
  mergeoldgen(g);
  separatetobefnz(g, 1);  /* separate all objects with finalizers */
  lua_assert(g->finobj == NULL);
  callallpendingfinalizers(L);
  lua_assert(g->tobefnz == NULL);
  g->currentwhite = WHITEBITS; /* this "white" makes all objects look dead */
  g->gckind = KGC_NORMAL;
  sweepwholelist(L, &g->finobj);
  sweepwholelist(L, &g->allgc);
  sweepwholelist(L, &g->fixedgc);  /* collect fixed objects */
  clearremlists(g, 0);
  lua_assert(g->strt.nuse == 0);
}


static l_mem atomic (lua_State *L) {
  global_State *g = G(L);
  l_mem work;
  GCObject *origweak, *origall;
  GCObject *grayagain = g->grayagain;  /* save original list */
  g->grayagain = NULL;
  lua_assert(g->ephemeron == NULL && g->weak == NULL);
  lua_assert(!iswhite(g->mainthread));
  g->gcstate = GCSinsideatomic;
  g->GCmemtrav = 0;  /* start counting work */
  markobject(g, L);  /* mark running thread */
  /* registry and global metatables may be changed by API */
  markvalue(g, &g->l_registry);
  markmt(g);  /* mark global metatables */
  markoldweak(g);
  /* remark occasional upvalues of (maybe) dead threads */
  remarkupvals(g);
  propagateall(g);  /* propagate changes */
  work = g->GCmemtrav;  /* stop counting (do not recount 'grayagain') */
  g->gray = grayagain;
  propagateall(g);  /* traverse 'grayagain' list */
  g->gray = g->grayatomic;
  g->grayatomic = NULL;
  propagateall(g);  /* traverse 'grayatomic' list (threads and weak tables) */
  g->GCmemtrav = 0;  /* restart counting */
  convergeephemerons(g);
  /* at this point, all strongly accessible objects are marked. */
  /* Clear values from weak tables, before checking finalizers */
  clearvalues(g, g->weak, NULL);
  clearvalues(g, g->allweak, NULL);
  origweak = g->weak; origall = g->allweak;
  work += g->GCmemtrav;  /* stop counting (objects being finalized) */
  separatetobefnz(g, 0);  /* separate objects to be finalized */
  g->gcfinnum = 1;  /* there may be objects to be finalized */
  markbeingfnz(g);  /* mark objects that will be finalized */
  propagateall(g);  /* remark, to propagate 'resurrection' */
  g->GCmemtrav = 0;  /* restart counting */
  convergeephemerons(g);
  /* at this point, all resurrected objects are marked. */
  /* remove dead objects from weak tables */
  clearkeys(g, g->ephemeron, NULL);  /* clear keys from all ephemeron tables */
  clearkeys(g, g->allweak, NULL);  /* clear keys from all 'allweak' tables */
  /* clear values from resurrected weak tables */
  clearvalues(g, g->weak, origweak);
  clearvalues(g, g->allweak, origall);
  /* if any old table became weak mid-cycle, restore its black mark */
  {
    GCObject *w;
    for (w = g->weak; w != NULL; w = gco2t(w)->gclist)
      if (isold(w)) { gray2black(w); gco2t(w)->flags &= cast_byte(~TM_WEAKBIT); resetbits(w->marked, bitmask(SURVIVALBIT) | bitmask(7)); }
    for (w = g->ephemeron; w != NULL; w = gco2t(w)->gclist)
      if (isold(w)) { gray2black(w); gco2t(w)->flags &= cast_byte(~TM_WEAKBIT); resetbits(w->marked, bitmask(SURVIVALBIT) | bitmask(7)); }
    for (w = g->allweak; w != NULL; w = gco2t(w)->gclist)
      if (isold(w)) { gray2black(w); gco2t(w)->flags &= cast_byte(~TM_WEAKBIT); resetbits(w->marked, bitmask(SURVIVALBIT) | bitmask(7)); }
  }
  luaS_clearcache(g);
  g->currentwhite = cast_byte(otherwhite(g));  /* flip current white */
  work += g->GCmemtrav;  /* complete counting */
  return work;  /* estimate of memory marked by 'atomic' */
}


static lu_mem sweepstep (lua_State *L, global_State *g,
                         int nextstate, GCObject **nextlist) {
  if (g->sweepgc) {
    l_mem olddebt = g->GCdebt;
    if (g->gcstate == GCSswpallgc && g->sweepgc == &g->tobeswept)
      g->sweepgc = sweeptobeswept(L, g->sweepgc, GCSWEEPMAX);
    else if (g->gcstate == GCSswpfinobj && g->tobesweptfin != NULL)
      g->sweepgc = sweepfinobj(g, g->sweepgc, GCSWEEPMAX);
    else
      g->sweepgc = sweeplist(L, g->sweepgc, GCSWEEPMAX);
    g->GCestimate += g->GCdebt - olddebt;  /* update estimate */
    if (g->sweepgc)  /* is there still something to sweep? */
      return (g->GCestimate > 4 * 1024 * 1024 && g->GCdebt > GCSTEPSIZE) ? (GCSWEEPMAX * GCSWEEPCOST * 4)
                                               : (GCSWEEPMAX * GCSWEEPCOST);
  }
  /* else enter next state */
  if (g->gcstate == GCSswpfinobj && g->tobesweptfin != NULL) {
    *findlast(&g->tobesweptfin) = g->oldfinobj;
    g->oldfinobj = g->tobesweptfin;
    g->tobesweptfin = NULL;
  }
  g->gcstate = nextstate;
  g->sweepgc = nextlist;
  return 0;
}


static lu_mem singlestep (lua_State *L) {
  global_State *g = G(L);
  switch (g->gcstate) {
    case GCSpause: {
      lu_mem totalbytes = gettotalbytes(g);
      if (g->inbleach)
        return bleachstep(g);
      if (g->needmajor || g->infullgc || !g->gcrunning ||
          (totalbytes < 512 * 1024 && g->minorcycles >= 1) ||
          (g->minorcycles >= 8) ||
          (g->lastmajbytes > 0 && totalbytes > g->lastmajbytes + (g->lastmajbytes / 3)) ||
          (g->lastmajcount > 0 && g->oldcount > g->lastmajcount + (g->lastmajcount >> 2))) {
        if (!g->infullgc && g->gcrunning &&
            (g->oldgc != NULL || g->oldfinobj != NULL)) {
          startbleach(g);
          return bleachstep(g);
        }
        mergeoldgen(g);
        g->ismajor = 1;
        g->minorcycles = 0;
      }
      else {
        g->ismajor = (g->oldgc == NULL && g->oldfinobj == NULL &&
                      g->oldweak == NULL);
        if (!g->ismajor)
          g->minorcycles++;
      }
      g->GCmemtrav = g->strt.size * sizeof(GCObject*);
      restartcollection(g);
      g->gcstate = GCSpropagate;
      return g->GCmemtrav;
    }
    case GCSpropagate: {
      g->GCmemtrav = 0;
      lua_assert(g->gray);
      propagatemark(g);
      if (g->gray == NULL) {  /* no more gray objects? */
        if (!g->drainedgray && g->grayagain != NULL) {
          g->drainedgray = 1;
          g->gray = g->grayagain;
          g->grayagain = NULL;
        }
        else
          g->gcstate = GCSatomic;  /* finish propagate phase */
      }
      return g->GCmemtrav;  /* memory traversed in this step */
    }
    case GCSatomic: {
      lu_mem work;
      propagateall(g);  /* make sure gray list is empty */
      work = atomic(L);  /* work is what was traversed by 'atomic' */
      entersweep(L);
      g->GCestimate = gettotalbytes(g);  /* first estimate */;
      return work;
    }
    case GCSswpallgc: {  /* sweep "regular" objects */
      GCObject **nextlist = (g->tobesweptfin != NULL) ? &g->tobesweptfin :
                            (!g->infullgc && g->gcrunning) ? NULL : &g->finobj;
      return sweepstep(L, g, GCSswpfinobj, nextlist);
    }
    case GCSswpfinobj: {  /* sweep objects with finalizers */
      return sweepstep(L, g, GCSswptobefnz, &g->tobefnz);
    }
    case GCSswptobefnz: {  /* sweep objects to be finalized */
      return sweepstep(L, g, GCSswpend, NULL);
    }
    case GCSswpend: {  /* finish sweeps */
      makewhite(g, g->mainthread);  /* sweep main thread */
      checkSizes(L, g);
      if (!g->infullgc) {
        lu_mem livebytes = g->GCestimate;
        if (g->ismajor || g->lastmajbytes == 0) {
          g->lastmajcount = g->oldcount;
          g->lastmajbytes = livebytes;
        }
        else if (livebytes > g->lastmajbytes + (g->lastmajbytes / 5)) {
          g->needmajor = 1;
        }
      }
      g->infullgc = 0;
      g->gcstate = GCScallfin;
      return 0;
    }
    case GCScallfin: {  /* call remaining finalizers */
      if (g->tobefnz && g->gckind != KGC_EMERGENCY) {
        int n = runafewfinalizers(L);
        return (n * GCFINALIZECOST);
      }
      else {  /* emergency mode or no more finalizers */
        g->gcstate = GCSpause;  /* finish collection */
        return 0;
      }
    }
    default: lua_assert(0); return 0;
  }
}


/*
** advances the garbage collector until it reaches a state allowed
** by 'statemask'
*/
void luaC_runtilstate (lua_State *L, int statesmask) {
  global_State *g = G(L);
  while (!testbit(statesmask, g->gcstate))
    singlestep(L);
}


/*
** get GC debt and convert it from Kb to 'work units' (avoid zero debt
** and overflows)
*/
static l_mem getdebt (global_State *g) {
  l_mem debt = g->GCdebt;
  int stepmul = g->gcstepmul;
  if (debt <= 0) return 0;  /* minimal debt */
  else {
    debt = (debt / STEPMULADJ) + 1;
    debt = (debt < MAX_LMEM / stepmul) ? debt * stepmul : MAX_LMEM;
    return debt;
  }
}

/*
** performs a basic GC step when collector is running
*/
#if defined(LUA_DEBUG)
void luaC_cleartestgray (global_State *g) {
  GCObject *o;
  for (o = g->gray; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
  for (o = g->grayagain; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
  for (o = g->grayatomic; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
  for (o = g->weak; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
  for (o = g->ephemeron; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
  for (o = g->allweak; o != NULL; o = *getgclist(o)) resetbit(o->marked, 7);
}
#endif

void luaC_step (lua_State *L) {
  global_State *g = G(L);
#if defined(LUA_DEBUG)
  luaC_cleartestgray(g);
#endif
  l_mem debt = getdebt(g);  /* GC deficit (be paid now) */
  if (!g->gcrunning) {  /* not running? */
    luaE_setdebt(g, -GCSTEPSIZE * 10);  /* avoid being called too often */
    return;
  }
  do {  /* repeat until pause or enough "credit" (negative debt) */
    int oldstate = g->gcstate;
    lu_mem work = singlestep(L);  /* perform one single step */
    debt -= work;
    if ((oldstate == GCSatomic || g->gcstate == GCSatomic) &&
        debt < cast(l_mem, gettotalbytes(g)))
      break;  /* isolate atomic phase into its own step */
  } while (debt > -GCSTEPSIZE && (g->gcstate != GCSpause || g->inbleach));
  if (g->gcstate == GCSpause && !g->inbleach)
    setpause(g);  /* pause until next cycle */
  else {
    debt = (debt / g->gcstepmul) * STEPMULADJ;  /* convert 'work units' to Kb */
    luaE_setdebt(g, debt);
    runafewfinalizers(L);
  }
}


/*
** Performs a full GC cycle; if 'isemergency', set a flag to avoid
** some operations which could change the interpreter state in some
** unexpected ways (running finalizers and shrinking some structures).
** Before running the collection, check 'keepinvariant'; if it is true,
** there may be some objects marked as black, so the collector has
** to sweep all objects to turn them back to white (as white has not
** changed, nothing will be collected).
*/
void luaC_fullgc (lua_State *L, int isemergency) {
  global_State *g = G(L);
  lua_assert(g->gckind == KGC_NORMAL);
  if (isemergency) g->gckind = KGC_EMERGENCY;  /* set flag */
  if (keepinvariant(g)) {  /* black objects? */
    mergeoldgen(g);
    g->infullgc = 1;
    entersweep(L); /* sweep everything to turn them back to white */
  }
  /* finish any pending sweep phase to start a new cycle */
  luaC_runtilstate(L, bitmask(GCSpause));
  g->infullgc = isemergency ? 1 : 0;
  mergeoldgen(g);
  luaC_runtilstate(L, ~bitmask(GCSpause));  /* start new collection */
  luaC_runtilstate(L, bitmask(GCScallfin));  /* run up to finalizers */
  g->infullgc = 0;
  /* estimate must be correct after a full GC cycle */
  lua_assert(g->GCestimate == gettotalbytes(g));
  luaC_runtilstate(L, bitmask(GCSpause));  /* finish collection */
  g->gckind = KGC_NORMAL;
  setpause(g);
}

/* }====================================================== */
