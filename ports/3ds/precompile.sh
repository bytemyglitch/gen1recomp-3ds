#!/usr/bin/env bash
# Compile the game's Lua to Lua 5.1 bytecode for the 3DS.
#
#   ports/3ds/precompile.sh OUT_DIR
#
# Parsing source is most of the 3DS boot time: plain Lua 5.1 on an 804 MHz
# ARM11 compiles roughly 100 KB of source a second.  Bytecode skips the parser.
#
# Lua 5.1 bytecode is only portable between builds with the same endianness,
# int/size_t/Instruction sizes and number type.  The 3DS is 32-bit little-
# endian with double numbers, so this builds a 32-bit (-m32) luac from the
# official lua-5.1.5 release, compiles every .lua the 3DS build ships under
# src/, tools/save-editor/, main.lua and conf.lua into OUT_DIR at the same
# relative paths (debug info kept, so tracebacks still name files and lines),
# then loads every result back with the matching 32-bit interpreter.
#
# Needs: curl, make, and gcc able to build -m32 (gcc-multilib on Ubuntu).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:?usage: precompile.sh OUT_DIR}"
WORK="$ROOT/.bazinga/3ds/luac32"
LUA_URL="https://www.lua.org/ftp/lua-5.1.5.tar.gz"
LUA_SHA256="2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK"
if [ ! -x "$WORK/lua-5.1.5/src/luac" ]; then
  say "building 32-bit Lua 5.1.5"
  curl -fsSL "$LUA_URL" -o "$WORK/lua.tgz"
  echo "$LUA_SHA256  $WORK/lua.tgz" | sha256sum -c - >/dev/null || fail "lua-5.1.5 checksum mismatch"
  tar -xzf "$WORK/lua.tgz" -C "$WORK"
  make -s -C "$WORK/lua-5.1.5/src" ansi CC="gcc -m32" >/dev/null
fi
LUAC="$WORK/lua-5.1.5/src/luac"
LUA="$WORK/lua-5.1.5/src/lua"

# The header every 3DS chunk must carry: ESC "Lua" 0x51, format 0,
# little-endian, int 4, size_t 4, Instruction 4, lua_Number 8, not integral.
EXPECTED="1b4c7561510001040404080"
probe="$WORK/probe.luac"
echo 'return 1' > "$WORK/probe.lua"
"$LUAC" -o "$probe" "$WORK/probe.lua"
header="$(head -c 12 "$probe" | od -An -tx1 | tr -d ' \n')"
[ "${header:0:23}" = "$EXPECTED" ] || fail "luac32 header $header is not the 3DS layout"

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"
count=0
while IFS= read -r -d '' file; do
  mkdir -p "$OUT/$(dirname "$file")"
  "$LUAC" -o "$OUT/$file" "$file"
  count=$((count + 1))
done < <(find src tools/save-editor main.lua conf.lua -name '*.lua' -print0)

say "checking $count chunks load in 32-bit Lua 5.1"
cat > "$WORK/verify.lua" <<'EOF'
local bad = 0
for path in io.lines(arg[1]) do
  local f, err = loadfile(path)
  if not f then bad = bad + 1; io.stderr:write(err, "\n") end
end
if bad > 0 then error(bad .. " chunk(s) failed to load") end
EOF
find "$OUT" -name '*.lua' > "$WORK/chunks.txt"
"$LUA" "$WORK/verify.lua" "$WORK/chunks.txt"
src_kb=$(find src tools/save-editor main.lua conf.lua -name '*.lua' -exec cat {} + | wc -c)
out_kb=$(find "$OUT" -name '*.lua' -exec cat {} + | wc -c)
say "compiled $count files: $((src_kb / 1024)) KB of source -> $((out_kb / 1024)) KB of bytecode in $OUT"
