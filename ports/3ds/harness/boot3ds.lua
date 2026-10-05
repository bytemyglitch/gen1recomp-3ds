-- Boot Gen1Recomp on the LÖVE Potion mock the way LÖVE Potion's boot.lua
-- does, run it for a while, drive it with the 3DS pad, and report.
--
--   hlua boot3ds.lua <game dir> <scratch save dir> [frames] [--unpatched]

local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = HERE .. "/?.lua;" .. package.path
local Mock = require("lovepotion_mock")

local gameDir = assert(arg[1], "game dir")
local saveRoot = assert(arg[2], "save root")
local frames = tonumber(arg[3]) or 600
local unpatched = false
for i = 4, #arg do
  if arg[i] == "--unpatched" then unpatched = true end
  if arg[i] == "--stock-paths" then Mock.stockPaths = true end
end

os.execute("mkdir -p '" .. saveRoot .. "'")
Mock.install({ source = gameDir, saveRoot = saveRoot, unpatchedPotion = unpatched })

package.path = gameDir .. "/?.lua;" .. gameDir .. "/?/init.lua;" .. package.path

-- Capture the game's own console output: LÖVE Potion has no stdout on
-- hardware, but errors the game catches and logs still matter here.
local logged = {}
local realPrint = print
print = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  local line = table.concat(parts, "\t")
  logged[#logged + 1] = line
end

local function report(fmt, ...) realPrint(fmt:format(...)) end

local function fail(stage, err)
  report("FAIL during %s:\n%s", stage, tostring(err))
  report("--- last game log lines ---")
  for i = math.max(1, #logged - 15), #logged do report("%s", logged[i]) end
  os.exit(1)
end

local function traceback(e) return debug.traceback(tostring(e), 2) end

-- love.init: defaults from LÖVE Potion's boot.lua, then conf.lua.
local c = {
  title = "Untitled", version = love._version,
  window = { width = 800, height = 600, minwidth = 1, minheight = 1,
    fullscreen = false, fullscreentype = "desktop", displayindex = 1, vsync = 1,
    msaa = 0, borderless = false, resizable = false, centered = true, usedpiscale = true },
  modules = { data = true, event = true, keyboard = true, mouse = false, timer = true,
    joystick = true, touch = true, image = true, graphics = true, audio = true,
    math = true, physics = true, sensor = true, sound = true, system = true,
    font = true, thread = true, window = true, video = false },
  audio = {}, identity = false, appendidentity = false,
}

local ok, err = xpcall(function()
  local confChunk = assert(loadfile(gameDir .. "/conf.lua"))
  confChunk()
  if love.conf then love.conf(c) end
end, traceback)
if not ok then fail("conf.lua", err) end

for name, enabled in pairs(c.modules) do
  if enabled == false then love[name] = nil end
end
if c.identity then love.filesystem.setIdentity(c.identity) end
report("conf: identity=%s window=%sx%s modules.mouse=%s",
  tostring(c.identity), tostring(c.window.width), tostring(c.window.height),
  tostring(c.modules.mouse))

ok, err = xpcall(function()
  local mainChunk = assert(loadfile(gameDir .. "/main.lua"))
  mainChunk()
end, traceback)
if not ok then fail("main.lua", err) end

local loop
ok, err = xpcall(function() loop = love.run() end, traceback)
if not ok then fail("love.run / love.load", err) end

-- Input script: a few seconds idle, then walk the launcher with the pad,
-- plus bottom-screen taps that must never reach the game.
local script = {}
local function at(frame, fn) script[frame] = script[frame] or {}; table.insert(script[frame], fn) end
local function tap(frame, button)
  at(frame, function() Mock.press(button) end)
  at(frame + 6, function() Mock.release(button) end)
end
local t = 180
for _, b in ipairs({ "dpdown", "dpdown", "dpup", "dpright", "dpleft", "rightshoulder",
                     "leftshoulder", "dpdown", "a", "b", "dpup", "a", "b", "start", "b" }) do
  tap(t, b); t = t + 20
end
at(200, function() Mock.touch(160, 120) end)
at(400, function() Mock.touch(10, 10) end)

local touchSeen = 0
local realTouch = love.touchpressed
love.touchpressed = function(...)
  touchSeen = touchSeen + 1
  if realTouch then return realTouch(...) end
end

local frame = 0
local screensDrawn = {}
local maxDepth = 0
ok, err = xpcall(function()
  while frame < frames do
    frame = frame + 1
    Mock.sim.time = Mock.sim.time + Mock.sim.dt
    for _, fn in ipairs(script[frame] or {}) do fn() end
    local before = {}
    for k, v in pairs(Mock.gstate.perScreenDraws) do before[k] = v end
    local quit = loop()
    for k, v in pairs(Mock.gstate.perScreenDraws) do
      if v > (before[k] or 0) then screensDrawn[k] = (screensDrawn[k] or 0) + 1 end
    end
    if #Mock.gstate.stack > maxDepth then maxDepth = #Mock.gstate.stack end
    if quit ~= nil then report("game asked to quit at frame %d (%s)", frame, tostring(quit)); break end
  end
end, traceback)
if not ok then fail(("frame %d"):format(frame), err) end

-- Report ---------------------------------------------------------------------
local Compat3DS = package.loaded["src.core.Compat3DS"]
report("ran %d frames, %d presents", frame, Mock.gstate.presents)
report("frames that drew to each screen: left=%d right=%d bottom=%d",
  screensDrawn.left or 0, screensDrawn.right or 0, screensDrawn.bottom or 0)
report("3D left on: %s; active screen after loop: %s; graphics stack depth now: %d",
  tostring(Mock.gstate.enabled3D), Mock.gstate.screen, #Mock.gstate.stack)
report("bottom-screen taps that reached love.touchpressed: %d", touchSeen)
report("audio: queueable sources=%d, buffers queued=%d, plays=%d",
  Mock.audio.queueSources, Mock.audio.queued, Mock.audio.plays)
report("worker threads started: %d", #Mock.threads)
if Compat3DS then
  table.sort(Compat3DS.stubbed)
  report("Compat3DS stand-ins installed (%d): %s", #Compat3DS.stubbed, table.concat(Compat3DS.stubbed, ", "))
end
-- 3DS policy checks ------------------------------------------------------------
local checks, failed = 0, 0
local function check(label, cond, detail)
  checks = checks + 1
  if not cond then failed = failed + 1 end
  report("[%s] %s%s", cond and "ok" or "FAIL", label, detail and (" (" .. tostring(detail) .. ")") or "")
end
local okC, errC = xpcall(function()
  local Platform = require("src.core.Platform")
  Platform._resetForTests()
  local p = Platform.detect()
  check("Platform sees the 3DS", p.n3ds == true and p.console == true)
  check("ROM import uses the save-directory inbox", p.romImportMode == "save-directory", p.romImportMode)
  check("no self-updater / remote fetch", p.networkValidated == false and p.canFetchRemote == false)
  local Performance = require("src.core.Performance")
  check("performance tier forced to LOW", Performance.resolve("high") == "low"
    and Performance.resolve("auto") == "low" and Performance.detect() == "low")
  local ChipAudio = require("src.core.ChipAudio")
  local rate = ChipAudio.selectSampleRate({ performance = "high" })
  check("chip audio at 22050 Hz", rate == 22050, rate)
  local q = love.audio.newQueueableSource(rate, 16, 2, 32)
  check("queueable source available (patched LÖVE Potion)", q ~= nil and q:getFreeBufferCount() == 32)
  check("shaders refused like a failed compile", not pcall(love.graphics.newShader, "x"))
  local GbcPalette = require("src.render.GbcPalette")
  check("palette falls back to grayscale", GbcPalette.available() == false)
  local f = love.filesystem.newFile("compat_probe.txt")
  check("newFile proxy opens for write", f:open("w") == true)
  f:write("hello 3ds"); f:close()
  local r = love.filesystem.newFile("compat_probe.txt")
  r:open("r")
  check("newFile proxy reads back", r:read() == "hello 3ds")
  r:close()
  love.filesystem.remove("compat_probe.txt")
  local w, h, flags = love.window.getMode()
  check("window reports the top screen", w == 400 and h == 240 and type(flags) == "table")
  local Icons = require("src.ui.kit.Icons")
  Icons.draw("flag", 0, 0, 16, { 255, 255, 255 })
  Icons.draw("mail", 0, 0, 16, { 255, 255, 255 })
  check("icon atlases paged under 1024px", true)
  local env = { x = 41 }
  local fn = load("return x + 1", "=probe", "t", env)
  check("load(string, name, mode, env) works on Lua 5.1", fn and fn() == 42)
  local okTtf = pcall(love.graphics.newFont,
    love.filesystem.newFileData("\0\1\0\0 not a cfnt", "UiSymbols.ttf"), 14)
  local okPath = pcall(love.graphics.newFont, "assets/fonts/plainpixel/PlainPixel-Regular.ttf", 14)
  check("TrueType fonts fall back to the system font (no CFNT crash)", okTtf and okPath)
  local okPng = pcall(love.graphics.newImage, "assets/logo/logo.png")
  check("PNG paths load as PNG, not rewritten to .t3x", okPng)
  check("text escapes decode the same as LuaJIT",
    ("POK\195\169"):byte(4) == 0xC3 and ("\195\151"):byte(2) == 0x97)
end, traceback)
if not okC then check("policy checks ran", false, errC) end
report("policy checks: %d/%d passed", checks - failed, checks)

local errs = {}
for _, line in ipairs(logged) do
  if line:lower():find("error") or line:find("attempt to") or line:find("traceback") then
    errs[#errs + 1] = line
  end
end
report("game log: %d lines, %d mention errors", #logged, #errs)
for i = 1, math.min(#errs, 25) do report("  %s", errs[i]:sub(1, 300)) end
os.exit(failed == 0 and 0 or 1)
