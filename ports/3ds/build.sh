#!/usr/bin/env bash
# Build Gen1Recomp for the Nintendo 3DS (New 3DS / New 3DS XL recommended).
#
#   ports/3ds/build.sh                       build patched LÖVE Potion, then fuse
#   ports/3ds/build.sh --lovepotion F.3dsx   fuse with a LÖVE Potion you already built
#
# Output: dist/3ds/gen1recomp.3dsx  -> copy to sdmc:/3ds/gen1recomp/gen1recomp.3dsx
#
# LÖVE Potion is built from lovebrew/lovepotion at a pinned commit with
# ports/3ds/lovepotion-3ds.patch applied (queueable audio sources, PNG
# decoding, and two audio fixes).  It needs devkitARM: either devkitPro's
# `catnip` on PATH, or Docker (the devkitpro/devkitarm image LÖVE Potion's
# own CI uses).  The game itself is packed with scripts/pack_love.sh and
# appended to the .3dsx, which is how LÖVE Potion finds a fused game.
#
# No ROM and no ROM-derived data ever goes into the build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$ROOT/.bazinga/3ds"
DIST="$ROOT/dist/3ds"
PATCH="$ROOT/ports/3ds/lovepotion-3ds.patch"
LOVEPOTION_REPO="https://github.com/lovebrew/lovepotion.git"
LOVEPOTION_REF="906511d"   # dev/3.0, Apr 26 2026 (3.0.2 line)
LOVEPOTION_3DSX=""

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lovepotion) LOVEPOTION_3DSX="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

mkdir -p "$WORK" "$DIST"

build_lovepotion() {
  local src="$WORK/lovepotion"
  if [ ! -d "$src/.git" ]; then
    say "cloning LÖVE Potion"
    git clone -q "$LOVEPOTION_REPO" "$src"
  fi
  git -C "$src" checkout -q -f "$LOVEPOTION_REF"
  git -C "$src" clean -qfdx
  say "applying $(basename "$PATCH")"
  git -C "$src" apply --whitespace=nowarn "$PATCH"

  local cmd="catnip -T 3DS -DLIBRARY_LOADER=linktime -DUSE_CURL_BACKEND=ON"
  if command -v catnip >/dev/null 2>&1; then
    say "building with local devkitARM"
    (cd "$src" && $cmd)
  elif command -v docker >/dev/null 2>&1; then
    say "building in the devkitpro/devkitarm container"
    docker run --rm -v "$src":/src -w /src devkitpro/devkitarm $cmd
  else
    fail "need devkitPro's catnip (https://devkitpro.org/wiki/Getting_Started) or Docker"
  fi

  LOVEPOTION_3DSX="$(find "$src/build" -name '*.3dsx' -print -quit)"
  [ -n "$LOVEPOTION_3DSX" ] || fail "LÖVE Potion built, but no .3dsx under $src/build"
  cp "$LOVEPOTION_3DSX" "$DIST/lovepotion-patched.3dsx"
  say "LÖVE Potion: $LOVEPOTION_3DSX"
}

if [ -z "$LOVEPOTION_3DSX" ]; then
  build_lovepotion
else
  [ -f "$LOVEPOTION_3DSX" ] || fail "no such file: $LOVEPOTION_3DSX"
  say "using $LOVEPOTION_3DSX (it must include ports/3ds/lovepotion-3ds.patch)"
fi

say "packing game.love"
"$ROOT/scripts/pack_love.sh" --output "$WORK/game.love" --listing "$WORK/love-listing.txt" >/dev/null

OUT="$DIST/gen1recomp.3dsx"
cat "$LOVEPOTION_3DSX" "$WORK/game.love" > "$OUT"
say "built $OUT ($(du -h "$OUT" | cut -f1))"
cat >&2 <<EOF

Copy to the SD card:
  sdmc:/3ds/gen1recomp/gen1recomp.3dsx

Launch it from the Homebrew Launcher.  The first boot shows the launcher;
ports/3ds/README.md explains getting your ROM's data onto the card.
EOF
