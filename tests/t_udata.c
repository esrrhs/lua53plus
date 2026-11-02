/* Minimal helper: bare userdata for GC path coverage (no default __gc).
 * Build (from repo root):
 *   gcc -std=gnu99 -O0 -g -fPIC -I src -shared -o tests/t_udata.so tests/t_udata.c
 * Loaded optionally by tests/test_gc_fuzz.lua via package.loadlib.
 */
#include "lua.h"
#include "lauxlib.h"

static int t_new(lua_State *L) {
  size_t n = (size_t)luaL_optinteger(L, 1, 8);
  lua_newuserdata(L, n);
  return 1;
}

static int t_setuv(lua_State *L) {
  luaL_checktype(L, 1, LUA_TUSERDATA);
  lua_settop(L, 2);
  lua_setuservalue(L, 1);
  return 0;
}

static const luaL_Reg funcs[] = {
  {"new", t_new},
  {"setuv", t_setuv},
  {NULL, NULL}
};

int luaopen_t_udata(lua_State *L) {
  luaL_newlib(L, funcs);
  return 1;
}
