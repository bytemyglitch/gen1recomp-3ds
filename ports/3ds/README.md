# Gen1Recomp on Nintendo 3DS

Unofficial port to the 3DS through [LÖVE Potion](https://github.com/lovebrew/lovepotion).
Target: **New 3DS / New 3DS XL** running Luma3DS with the Homebrew Launcher.
Pokémon Red and Blue only. An original 3DS will boot it but is likely too slow.

## Build

**On GitHub (no toolchain needed):** push this branch to your fork, open
**Actions → Nintendo 3DS → Run workflow**, and download `gen1recomp-3ds` from
the finished run.

**Locally:** run `ports/3ds/build.sh`. It needs devkitPro's `catnip` on
PATH, or Docker. It builds LÖVE Potion at a pinned commit with
`lovepotion-3ds.patch` applied, packs the game, and writes
`dist/3ds/gen1recomp.3dsx`.

## Install

1. Copy `gen1recomp.3dsx` to `sdmc:/3ds/gen1recomp/` on the SD card.
2. Launch **gen1recomp** from the Homebrew Launcher. The first boot opens the launcher.
3. The launcher shows its save folder on the SD card. Put your own US Red or
   Blue ROM (`.gb`, 1 MiB) in that folder's `imports/` subfolder.
4. Choose **Scan again**. The import is slow in plain Lua on the 3DS; give it
   a few minutes. It runs once per version. Afterwards the ROM file can be
   deleted from `imports/`.

The build never contains a ROM or any data taken from one.

## Controls

| 3DS | Game |
| --- | --- |
| D-pad / Circle Pad | Move |
| A / B | A / B |
| START / SELECT | Start / Select |
| Hold START + SELECT for 5 s | Force quit |

The bottom screen stays black, and touches on it are ignored.

## What differs from the PC version

- **Gen 1 only.** The 3DS launcher lists Red, Blue and Yellow.

- **No shader effects.** The 3DS GPU cannot run GLSL, so COLORS, TILT, ZOOM,
  GBC FX and SHADER FX are off. The game is drawn in the original grayscale.
- **Performance tier is locked to LOW**, so music is synthesized at 22,050 Hz.
- **No self-updater or online mod catalog.** Link play has not been tried on a console.
- **No launcher video or splash animation.**
- **No 3D.** The launcher's cartridge is drawn flat and front-on instead of
  as a spinning 3D model, and the in-game TILT view stays off.
- The picture is the Game Boy's 160×144 at 1× on the 400×240 top screen.

## What changed, and why

LÖVE Potion (`lovepotion-3ds.patch`):

- `love.audio.newQueueableSource` was an empty, unregistered stub, and
  queueable sources had no 3DS backend. All the game's music streams through
  one, so this is implemented on the 3DS DSP.
- PNG decoding was registered only for Switch and Wii U. The 3DS now decodes
  PNG as well, which the game's art and its import cache need.
- Static sound effects freed their shared sample memory twice when collected.
- `Source:setVolume` was lost whenever a source started playing.
- On 3DS every `.png`/`.jpg` path was silently opened as `.t3x` (and `.ttf`
  as `.bcfnt`), so no PNG could ever load. It now falls back to the converted
  file only when the file asked for is missing.
- Every font copied the whole ~3 MB system font into linear memory. After a
  handful of text sizes the allocation failed and the console crashed
  (Luma3DS data abort in `memcpy`). Fonts built from the same data now share
  one copy, and non-CFNT data raises a Lua error instead of crashing.
- PNGs were handed to the 3DS GPU as plain rows, but on 3DS an `ImageData`
  must be tiled, padded to power-of-two sizes, with bytes in A,B,G,R order.
  Every decoded image came out scrambled, and every PNG the ROM importer
  wrote was scrambled on disk. Decoding and encoding now convert at the
  boundary; caches imported before this fix are flagged for one re-import.
- Worker threads never got the `bit` library (only the main Lua state
  did), so the music synthesizer thread failed at `require("bit")`.

Gen1Recomp:

- `src/core/Compat3DS.lua` supplies safe stand-ins for the LÖVE 11 desktop
  calls LÖVE Potion lacks (shaders, mouse, keyboard polling, window queries
  and a few others). It also adds a Lua 5.2-style `load`, which LuaJIT has
  and LÖVE Potion's Lua 5.1 lacks. On every other platform it does nothing.
- TrueType fonts can't be used on 3DS: its rasterizer reads only `.bcfnt`
  and crashes on anything else. The launcher's TTF faces use the system font.
- `main.lua` draws the game to the top screen only and drops bottom-screen
  touches. `conf.lua` sets up the 400×240 window.
- `Platform` and `Performance` recognize the 3DS. ROM import uses the
  save-folder inbox, the same flow as the Switch build.
- Fixes needed on Lua 5.1 that matter on every platform: `\x` string escapes
  became decimal (on 5.1, "POKé" and "×" printed as literal `xc3xa9`), the
  GBA importers no longer use `goto`, the version rail can no longer index
  past its last color, and a missing video decoder is no longer retried every frame.
- Boot time: the launcher used to check all eleven game versions at startup,
  and the Gen 3 checks parsed 2.7 MB of Emerald symbol tables. Boot now
  compiles 2.8 MB of Lua instead of 7.5 MB, and CI ships that Lua
  precompiled to bytecode (`precompile.sh`) so the console skips the parser.
- The launcher's icon atlases (1,728 and 3,168 px wide) are cut into pages
  under the 3DS GPU's 1,024 px texture limit.

## Testing without hardware

`ports/3ds/harness/run.sh` boots the game headless against a strict model of
LÖVE Potion's 3DS API. Each module and object exposes only what LÖVE Potion
registers, textures over 1,024 px fail, and only PNG and `.t3x` decode. The
harness runs 600 frames while the pad walks the launcher, then runs 14 policy
checks. It runs in CI before the build.

It cannot measure frame rate, memory use or audio timing, and it cannot get
past the launcher without a ROM. Those need a real console.
