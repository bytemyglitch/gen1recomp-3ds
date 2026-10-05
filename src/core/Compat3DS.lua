-- Nintendo 3DS (LÖVE Potion 3.x) compatibility layer.
--
-- LÖVE Potion implements most of the LÖVE 12 API on the 3DS, but the game
-- was written for LÖVE 11.5 desktop/mobile hosts and calls a few dozen
-- functions the 3DS build does not have: shaders (the PICA200 has no GLSL),
-- love.mouse (no module at all), keyboard polling, desktop window queries,
-- screenshots and a handful of host bridges.  About half of those call
-- sites already check for the function first; this file fills in the rest
-- with safe stand-ins so the unguarded ones cannot crash.
--
-- Every stand-in is only installed where the real function is missing, so
-- a future LÖVE Potion that grows one of these wins automatically.  Nothing
-- here runs off the 3DS: both entry points return early unless
-- love._console == "3DS".
--
-- Two entry points, because LÖVE Potion runs conf.lua before it loads the
-- other modules:
--   Compat3DS.installConf()  top of conf.lua      (only love.filesystem exists)
--   Compat3DS.install()      top of main.lua      (all enabled modules loaded)

local Compat3DS = {}

-- The top screen; the game only ever draws there.
Compat3DS.WIDTH = 400
Compat3DS.HEIGHT = 240

function Compat3DS.isActive()
  return love ~= nil and love._console == "3DS"
end

local function noop() end
local function returnsFalse() return false end
local function returnsTrue() return true end
local function returnsOne() return 1 end

-- Define tbl[name] only when the host did not provide it.
local function define(tbl, name, fn)
  if tbl and tbl[name] == nil then
    tbl[name] = fn
  end
end

-- Record what was stubbed so a debug overlay or log can show it.
Compat3DS.stubbed = {}

local function stub(moduleName, tbl, name, fn)
  if tbl and tbl[name] == nil then
    tbl[name] = fn
    Compat3DS.stubbed[#Compat3DS.stubbed + 1] = moduleName .. "." .. name
  end
end

-- LÖVE Potion runs PUC Lua 5.1, not LuaJIT.  The game (link fingerprints,
-- mod asset transforms, the mod sandbox) calls load(source, name, mode, env)
-- the Lua 5.2 way, which LuaJIT accepts and plain 5.1 rejects ("function
-- expected, got string").  This load takes both forms.
local function installLanguage()
  if Compat3DS._languageInstalled then return end
  Compat3DS._languageInstalled = true
  if _VERSION ~= "Lua 5.1" or rawget(_G, "jit") ~= nil then return end
  local load51 = load
  _G.load = function(chunk, chunkname, mode, env)
    local fn, err
    if type(chunk) == "string" then
      local binary = chunk:byte(1) == 27
      if mode == "t" and binary then
        return nil, "attempt to load a binary chunk (mode is 't')"
      elseif mode == "b" and not binary then
        return nil, "attempt to load a text chunk (mode is 'b')"
      end
      fn, err = loadstring(chunk, chunkname)
    else
      fn, err = load51(chunk, chunkname)
    end
    if fn and env ~= nil then setfenv(fn, env) end
    return fn, err
  end
  Compat3DS.stubbed[#Compat3DS.stubbed + 1] = "_G.load (5.2 signature)"
end

function Compat3DS.installConf()
  if not Compat3DS.isActive() then return false end
  installLanguage()
  local fs = love.filesystem
  stub("filesystem", fs, "setSymlinksEnabled", noop)
  stub("filesystem", fs, "areSymlinksEnabled", returnsFalse)
  return true
end

---------------------------------------------------------------------------
-- graphics
---------------------------------------------------------------------------

-- No shader can be built on the PICA200.  newShader raises, exactly as a
-- failed compile does on desktop, so every caller that already wraps it in
-- pcall (GbcPalette, ShaderFX, the cart hover, the splash) takes its own
-- no-shader fallback: GbcPalette, for one, falls back to the plain grayscale
-- draw.  setShader/getShader then only ever see nil.
Compat3DS.SHADER_ERROR = "shaders are not available on Nintendo 3DS"

local function installGraphics()
  local g = love.graphics
  if not g then return end

  stub("graphics", g, "newShader", function()
    error(Compat3DS.SHADER_ERROR, 2)
  end)
  stub("graphics", g, "setShader", noop)
  stub("graphics", g, "getShader", function() return nil end)
  -- Report every shader as invalid so code that validates before building
  -- takes its no-shader branch without even trying.
  stub("graphics", g, "validateShader", function()
    return false, Compat3DS.SHADER_ERROR
  end)
  stub("graphics", g, "captureScreenshot", noop)
  stub("graphics", g, "flushBatch", noop)
  stub("graphics", g, "getDPIScale", returnsOne)
  stub("graphics", g, "getSupported", function()
    return {
      shaderderivatives = false, glsl3 = false, glsl4 = false,
      instancing = false, fullnpot = false, pixelshaderhighp = false,
      clampzero = false, lighten = false, multicanvasformats = false,
    }
  end)

  -- One picture on the top screen; stereoscopic 3D would draw everything
  -- twice for an image that has no depth.
  if g.set3D then pcall(g.set3D, false) end
end

---------------------------------------------------------------------------
-- input
---------------------------------------------------------------------------

local function installInput()
  -- The 3DS has no mouse; LÖVE Potion does not ship the module at all.
  if love.mouse == nil then
    love.mouse = {}
    Compat3DS.stubbed[#Compat3DS.stubbed + 1] = "mouse.*"
  end
  local m = love.mouse
  define(m, "getPosition", function() return 0, 0 end)
  define(m, "getX", function() return 0 end)
  define(m, "getY", function() return 0 end)
  define(m, "isDown", returnsFalse)
  define(m, "setPosition", noop)
  define(m, "setVisible", noop)
  define(m, "isVisible", returnsFalse)
  define(m, "isCursorSupported", returnsFalse)
  define(m, "setCursor", noop)
  define(m, "getCursor", function() return nil end)
  define(m, "getSystemCursor", function() return nil end)
  define(m, "setGrabbed", noop)
  define(m, "isGrabbed", returnsFalse)
  define(m, "setRelativeMode", noop)
  define(m, "getRelativeMode", returnsFalse)

  -- Only the software keyboard exists; nothing is ever "held".
  love.keyboard = love.keyboard or {}
  local k = love.keyboard
  stub("keyboard", k, "isDown", returnsFalse)
  stub("keyboard", k, "isScancodeDown", returnsFalse)
  stub("keyboard", k, "setKeyRepeat", noop)
  stub("keyboard", k, "hasKeyRepeat", returnsFalse)
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------

local function installWindow()
  love.window = love.window or {}
  local w = love.window
  local W, H = Compat3DS.WIDTH, Compat3DS.HEIGHT

  -- Always describe the top screen, whichever screen happens to be active.
  stub("window", w, "getMode", function()
    return W, H, {
      fullscreen = true, fullscreentype = "desktop", vsync = 1, msaa = 0,
      resizable = false, borderless = true, centered = true, display = 1,
      minwidth = W, minheight = H, highdpi = false, usedpiscale = false,
      refreshrate = 60, x = 0, y = 0,
    }
  end)
  stub("window", w, "getDesktopDimensions", function() return W, H end)
  stub("window", w, "getSafeArea", function() return 0, 0, W, H end)
  stub("window", w, "setFullscreen", returnsTrue)
  stub("window", w, "getFullscreen", function() return true, "desktop" end)
  stub("window", w, "hasFocus", returnsTrue)
  stub("window", w, "hasMouseFocus", returnsFalse)
  stub("window", w, "isVisible", returnsTrue)
  stub("window", w, "isMinimized", returnsFalse)
  stub("window", w, "getDPIScale", returnsOne)
  stub("window", w, "setVSync", noop)
  stub("window", w, "getVSync", returnsOne)
  stub("window", w, "close", noop)
  stub("window", w, "setPosition", noop)
  stub("window", w, "getPosition", function() return 0, 0, 1 end)
  stub("window", w, "getDisplayCount", returnsOne)
  stub("window", w, "getDisplayName", function() return "Nintendo 3DS" end)
  stub("window", w, "showFileDialog", returnsFalse)
  stub("window", w, "requestAttention", noop)
  stub("window", w, "toPixels", function(v, v2) return v, v2 end)
  stub("window", w, "fromPixels", function(v, v2) return v, v2 end)
end

---------------------------------------------------------------------------
-- filesystem / system / arg
---------------------------------------------------------------------------

-- LÖVE 11's newFile(path) returns an unopened File that the caller opens
-- later; LÖVE Potion only has openFile(path, mode).  The proxy opens the
-- real file on :open() and forwards every other method to it.
local function newFileProxy(fs, path)
  local real = nil
  local proxy = {}
  function proxy:open(mode)
    local file, err = fs.openFile(path, mode)
    if not file then return false, err end
    real = file
    return true
  end
  function proxy:isOpen() return real ~= nil and real:isOpen() end
  function proxy:getFilename() return path end
  function proxy:close()
    if not real then return false end
    local ok = real:close()
    real = nil
    return ok
  end
  return setmetatable(proxy, {
    __index = function(_, key)
      return function(_, ...)
        if not real then
          error(("File '%s' is not open"):format(path), 2)
        end
        return real[key](real, ...)
      end
    end,
  })
end

local function installFilesystem()
  local fs = love.filesystem
  if not fs then return end
  stub("filesystem", fs, "setSymlinksEnabled", noop)
  stub("filesystem", fs, "areSymlinksEnabled", returnsFalse)
  if fs.newFile == nil and fs.openFile then
    fs.newFile = function(path, mode)
      if mode and mode ~= "c" then return fs.openFile(path, mode) end
      return newFileProxy(fs, path)
    end
    Compat3DS.stubbed[#Compat3DS.stubbed + 1] = "filesystem.newFile"
  end
end

local function installSystem()
  local s = love.system
  if not s then return end
  local clipboard = ""
  stub("system", s, "openURL", returnsFalse)
  stub("system", s, "getClipboardText", function() return clipboard end)
  stub("system", s, "setClipboardText", function(text) clipboard = text or "" end)
  stub("system", s, "vibrate", noop)
  stub("system", s, "hasBackgroundMusic", returnsFalse)
end

local function installArg()
  love.arg = love.arg or {}
  stub("arg", love.arg, "parseGameArguments", function(args) return args or {} end)
end

function Compat3DS.install()
  if not Compat3DS.isActive() then return false end
  installLanguage()
  installGraphics()
  installInput()
  installWindow()
  installFilesystem()
  installSystem()
  installArg()
  return true
end

---------------------------------------------------------------------------
-- frame and events
---------------------------------------------------------------------------

-- The bottom screen's touch panel arrives as touch (and, on some builds,
-- mouse) events in 320x240 bottom-screen coordinates.  The game would read
-- them as taps on its top-screen layout, so they are dropped.
Compat3DS.DROPPED_EVENTS = {
  touchpressed = true, touchmoved = true, touchreleased = true,
  mousepressed = true, mousereleased = true, mousemoved = true,
  wheelmoved = true,
}

function Compat3DS.dropsEvent(name)
  return Compat3DS.DROPPED_EVENTS[name] == true
end

-- Optional bottom-screen painter (nil = plain black).  Set by whoever wants
-- the second screen; called with the 320x240 screen active.
Compat3DS.drawBottom = nil

-- Replaces the single draw/present of the desktop loop.  The bottom screen
-- is drawn first so the top ("left") screen is still the active one when
-- love.update runs next frame: love.graphics.getDimensions reports the
-- active screen, and the game lays itself out from it.
function Compat3DS.drawFrame(drawGame)
  local g = love.graphics
  local screens = g.getScreens and g.getScreens() or { "left" }
  local ordered = {}
  for _, screen in ipairs(screens) do
    if screen == "bottom" then table.insert(ordered, 1, screen)
    else ordered[#ordered + 1] = screen end
  end
  for _, screen in ipairs(ordered) do
    if g.setActiveScreen then g.setActiveScreen(screen) end
    g.origin()
    if screen == "bottom" then
      g.clear(0, 0, 0, 1)
      if Compat3DS.drawBottom then Compat3DS.drawBottom() end
    else
      g.clear(g.getBackgroundColor())
      if drawGame then drawGame(screen) end
    end
  end
  g.present()
end

return Compat3DS
