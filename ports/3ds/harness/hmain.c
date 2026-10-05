/* Lua 5.1 host for the LÖVE Potion API mock: same bit/utf8 libs LÖVE Potion preloads. */
#include <stdio.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
int luaopen_bit(lua_State *L);
int luaopen_luautf8(lua_State *L);
static int traceback(lua_State *L) {
  lua_getfield(L, LUA_GLOBALSINDEX, "debug");
  lua_getfield(L, -1, "traceback");
  lua_pushvalue(L, 1); lua_pushinteger(L, 2); lua_call(L, 2, 1); return 1;
}
int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: hlua script.lua [args]\n"); return 2; }
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  luaopen_bit(L); lua_pop(L, 1);
  lua_getfield(L, LUA_GLOBALSINDEX, "package"); lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, luaopen_luautf8); lua_setfield(L, -2, "utf8"); lua_pop(L, 2);
  lua_newtable(L);
  for (int i = 0; i < argc; i++) { lua_pushstring(L, argv[i]); lua_rawseti(L, -2, i - 1); }
  lua_setglobal(L, "arg");
  lua_pushcfunction(L, traceback);
  if (luaL_loadfile(L, argv[1])) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
  if (lua_pcall(L, 0, 0, -2)) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
  lua_close(L); return 0;
}
