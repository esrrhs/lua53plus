/*
** $Id: ltable.h,v 2.23 2016/12/22 13:08:50 roberto Exp $
** Lua tables (hash)
** See Copyright Notice in lua.h
*/

#ifndef ltable_h
#define ltable_h

#include "lobject.h"


#define gnode(t,i)	(&(t)->node[i])
#define gval(n)		(&(n)->i_val)
#define gnext(n)	((n)->i_key.nk.next)


/* 'const' to avoid wrong writings that can mess up field 'next' */
#define gkey(n)		cast(const TValue*, (&(n)->i_key.tvk))

/*
** writable version of 'gkey'; allows updates to individual fields,
** but not to the whole (which has incompatible type)
*/
#define wgkey(n)		(&(n)->i_key.nk)

#define invalidateTMcache(t)	((t)->flags = 0)


/* true when 't' is using 'dummynode' as its hash part */
#define isdummy(t)		((t)->lastfree == NULL)


/* allocated size for hash nodes */
#define allocsizenode(t)	(isdummy(t) ? 0 : sizenode(t))


/* returns the key, given the value of a table entry */
#define keyfromval(v) \
  (gkey(cast(Node *, cast(char *, (v)) - offsetof(Node, i_val))))


#define hashpow2(t,n)		(gnode(t, lmod((n), sizenode(t))))
#define hashstr(t,str)		hashpow2(t, (str)->hash)
#define hashboolean(t,p)	hashpow2(t, p)
#define hashint(t,i)		hashpow2(t, i)


LUAI_FUNC const TValue *luaH_getint (Table *t, lua_Integer key);
LUAI_FUNC void luaH_setint (lua_State *L, Table *t, lua_Integer key,
                                                    TValue *value);
LUAI_FUNC const TValue *luaH_getshortstr (Table *t, TString *key);
LUAI_FUNC const TValue *luaH_getstr (Table *t, TString *key);
LUAI_FUNC const TValue *luaH_get (Table *t, const TValue *key);

/*
** Inlined fast-path lookups for short strings and integer array keys.
** Checks the primary hash bucket (or array slot) inline and falls back
** to the out-of-line probe loop only when a collision chain exists.
*/
static l_inline const TValue *luaH_fastgetshortstr (Table *t, TString *key) {
  Node *n = hashstr(t, key);
  for (;;) {
    const TValue *k = gkey(n);
    if (l_likely(val_(k).gc == cast(GCObject *, key) && ttisshrstring(k)))
      return gval(n);
    {
      int nx = gnext(n);
      if (nx == 0)
        return luaO_nilobject;
      n += nx;
    }
  }
}

static l_inline const TValue *luaH_fastgetstr (Table *t, TString *key) {
  if (l_likely(key->tt == LUA_TSHRSTR))
    return luaH_fastgetshortstr(t, key);
  else
    return luaH_getstr(t, key);
}

static l_inline const TValue *luaH_fastget (Table *t, const TValue *key) {
  if (ttisshrstring(key))
    return luaH_fastgetshortstr(t, tsvalue(key));
  else if (ttisinteger(key)) {
    lua_Integer k = ivalue(key);
    if (l_likely(l_castS2U(k) - 1u < t->sizearray))
      return &t->array[k - 1];
    return luaH_getint(t, k);
  }
  else
    return luaH_get(t, key);
}
LUAI_FUNC TValue *luaH_newkey (lua_State *L, Table *t, const TValue *key);
LUAI_FUNC TValue *luaH_set (lua_State *L, Table *t, const TValue *key);
LUAI_FUNC Table *luaH_new (lua_State *L);
LUAI_FUNC void luaH_resize (lua_State *L, Table *t, unsigned int nasize,
                                                    unsigned int nhsize);
LUAI_FUNC void luaH_resizearray (lua_State *L, Table *t, unsigned int nasize);
LUAI_FUNC void luaH_free (lua_State *L, Table *t);
LUAI_FUNC int luaH_next (lua_State *L, Table *t, StkId key);
LUAI_FUNC int luaH_getn (Table *t);


#if defined(LUA_DEBUG)
LUAI_FUNC Node *luaH_mainposition (const Table *t, const TValue *key);
LUAI_FUNC int luaH_isdummy (const Table *t);
#endif


#endif
