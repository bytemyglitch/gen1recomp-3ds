#!/usr/bin/env bash
# Boot Gen1Recomp headless against a strict LÖVE Potion 3DS API mock.
#
#   ports/3ds/harness/run.sh [frames]
#
# Builds a Lua 5.1 interpreter with the same bit/utf8 libraries LÖVE Potion
# preloads (first run only; needs git and a C compiler), then runs
# boot3ds.lua: conf.lua -> main.lua -> love.run for N frames while the 3DS
# pad walks the launcher.  It fails on any call the real LÖVE Potion 3DS
# build does not provide, on textures over the GPU's 1024px limit, on image
# formats the 3DS cannot decode, and on any of the 3DS policy checks.
#
# What it cannot tell you: frame rate, memory, and anything past the
# launcher (that needs a ROM-derived cache, which this repository never has).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WORK="$ROOT/.bazinga/3ds-harness"
FRAMES="${1:-600}"
shift || true   # anything after the frame count goes to boot3ds.lua (e.g. --ready)
LOVEPOTION_REF="906511d"

mkdir -p "$WORK"
if [ ! -x "$WORK/hlua" ]; then
  echo "==> building Lua 5.1 host (one time)"
  [ -d "$WORK/lua51" ] || git clone -q --depth 1 -b v5.1 https://github.com/lua/lua.git "$WORK/lua51"
  if [ ! -d "$WORK/lovepotion" ]; then
    git clone -q https://github.com/lovebrew/lovepotion.git "$WORK/lovepotion"
    git -C "$WORK/lovepotion" checkout -q "$LOVEPOTION_REF"
  fi
  LP="$WORK/lovepotion/libraries"
  SRC=$(ls "$WORK"/lua51/*.c | grep -vE '/(lua|luac|ltests|print)\.c$')
  # shellcheck disable=SC2086
  cc -O2 -w -DLUA_USE_POSIX -DLUA_USE_DLOPEN -I"$WORK/lua51" -I"$LP/lua53" \
    -o "$WORK/hlua" "$HERE/hmain.c" $SRC "$LP/luabit/bit.c" "$LP/lua53/lutf8lib.c" -lm -ldl
fi

SAVE="$WORK/save"
rm -rf "$SAVE"
cd "$HERE"
exec "$WORK/hlua" boot3ds.lua "$ROOT" "$SAVE" "$FRAMES" "$@"
