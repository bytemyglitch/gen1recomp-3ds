-- A headless stand-in for LÖVE Potion 3.x on Nintendo 3DS, for boot-testing
-- Gen1Recomp without hardware.
--
-- Strict by construction: each love.<module> table holds ONLY the functions
-- LÖVE Potion registers on 3DS (lp_funcs.txt, extracted from its C++ binding
-- tables and Lua scripts), and every object carries ONLY the methods its
-- LÖVE Potion type registers (lp_methods.txt).  A call the real console
-- would reject as "attempt to call a nil value" fails the same way here.
-- Behaviour behind those functions is simulated just enough for the game's
-- own logic to run: the filesystem is real (game folder read-only, a scratch
-- save folder writable), image loading accepts only what the patched 3DS
-- build decodes (PNG and .t3x), and nothing is drawn.

local Mock = {}

local HERE = (arg and arg[0] or ""):match("^(.*)/[^/]*$") or "."

local function readLines(path)
  local list = {}
  for line in io.lines(path) do
    if line ~= "" then list[#list + 1] = line end
  end
  return list
end

-- module -> { name = true }, type -> { method = true }
local FUNCS, METHODS = {}, {}
for _, entry in ipairs(readLines(HERE .. "/lp_funcs.txt")) do
  local mod, fn = entry:match("^([%w_]+)%.([%w_]+)$")
  if mod and not (mod == fn) then
    FUNCS[mod] = FUNCS[mod] or {}
    FUNCS[mod][fn] = true
  end
end
for _, entry in ipairs(readLines(HERE .. "/lp_methods.txt")) do
  local t, m = entry:match("^([%w_]+):([%w_]+)$")
  if t then
    METHODS[t] = METHODS[t] or {}
    METHODS[t][m] = true
  end
end
-- methods LÖVE Potion adds from Lua (include/scripts/wrap_*.lua)
METHODS.imagedata.mapPixel = true
METHODS.randomgenerator = METHODS.randomgenerator or {}
METHODS.randomgenerator.random = true

-- Inherited methods: LÖVE Potion's type hierarchy (Drawable/Data/Object).
local INHERITS = {
  imagedata = { "data" }, sounddata = { "data" }, bytedata = { "data" },
  filedata = { "data" }, compresseddata = { "data" }, dataview = { "data" },
  compressedimagedata = { "data" },
}

Mock.missingCalls = {}
Mock.callCounts = {}

local function note(kind, name)
  Mock.callCounts[name] = (Mock.callCounts[name] or 0) + 1
end

---------------------------------------------------------------------------
-- objects
---------------------------------------------------------------------------

local TYPE_NAMES = {
  texture = "Texture", quad = "Quad", font = "Font", spritebatch = "SpriteBatch",
  textbatch = "TextBatch", mesh = "Mesh", imagedata = "ImageData",
  sounddata = "SoundData", source = "Source", file = "File",
  filedata = "FileData", bytedata = "ByteData", data = "Data",
  channel = "Channel", luathread = "Thread", joystick = "Joystick",
  randomgenerator = "RandomGenerator", transform = "Transform",
  decoder = "Decoder", rasterizer = "Rasterizer", glyphdata = "GlyphData",
  compresseddata = "CompressedData", dataview = "DataView",
}

local objectMeta = {}

-- `impl` supplies behaviour; only names LÖVE Potion registers for the type
-- (or its parents) become callable.
local function newObject(kind, impl, state)
  local allowed = {}
  for m in pairs(METHODS[kind] or {}) do allowed[m] = true end
  for _, parent in ipairs(INHERITS[kind] or {}) do
    for m in pairs(METHODS[parent] or {}) do allowed[m] = true end
  end
  local methods = {}
  for m in pairs(allowed) do
    local f = impl[m]
    methods[m] = f or function() return nil end
  end
  local typeName = TYPE_NAMES[kind] or kind
  methods.release = function(self) self.__released = true return true end
  methods.type = function() return typeName end
  methods.typeOf = function(_, name)
    if name == typeName or name == "Object" then return true end
    if kind == "texture" and (name == "Drawable") then return true end
    for _, parent in ipairs(INHERITS[kind] or {}) do
      if TYPE_NAMES[parent] == name then return true end
    end
    return false
  end
  -- Userdata-like: a table whose fields are only the allowed methods.
  local obj = state or {}
  return setmetatable(obj, {
    __index = function(_, key) return methods[key] end,
    __newindex = function(t, key, value) rawset(t, key, value) end,
    __tostring = function() return typeName .. ": mock" end,
    __mockKind = kind,
  })
end
Mock.newObject = newObject

---------------------------------------------------------------------------
-- filesystem (real disk)
---------------------------------------------------------------------------

local function shellQuote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function isDir(path)
  local ok = os.execute("test -d " .. shellQuote(path))
  return ok == 0 or ok == true
end

local function isFile(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local okRead = f:read(0) ~= nil or true
  f:close()
  return okRead and not isDir(path)
end

local function listDir(path)
  local items = {}
  local p = io.popen("ls -1A " .. shellQuote(path) .. " 2>/dev/null")
  if p then
    for name in p:lines() do items[#items + 1] = name end
    p:close()
  end
  return items
end

local function fileSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

local function normalize(rel)
  rel = tostring(rel or ""):gsub("\\", "/"):gsub("/+", "/"):gsub("^%./", "")
  rel = rel:gsub("^/", ""):gsub("/$", "")
  return rel
end

function Mock.newFilesystem(sourceDir, saveRoot)
  local fs = {}
  local identity = "lovepotion"
  local saveDir = saveRoot .. "/" .. identity
  local fused = true

  local function savePath(rel) return saveDir .. (rel ~= "" and ("/" .. rel) or "") end
  local function sourcePath(rel) return sourceDir .. (rel ~= "" and ("/" .. rel) or "") end

  -- Save directory shadows the source, as in LÖVE.
  local function resolve(rel)
    rel = normalize(rel)
    local s = savePath(rel)
    if isFile(s) or isDir(s) then return s, "save" end
    local g = sourcePath(rel)
    if isFile(g) or isDir(g) then return g, "source" end
    return nil
  end
  Mock.resolvePath = resolve

  -- LÖVE Potion's translatePath (include/utilities/functions.hpp): on 3DS a
  -- .png/.jpg/.jpeg path is opened as .t3x and .ttf/.otf as .bcfnt.  Stock
  -- 3.0.2 always swaps; the patched build only swaps when the file asked for
  -- is missing.
  local function translate(rel)
    rel = tostring(rel)
    if not Mock.stockPaths and resolve(rel) then return rel end
    local lower = rel:lower()
    for _, ext in ipairs({ ".png", ".jpg", ".jpeg" }) do
      if lower:sub(-#ext) == ext then return rel:sub(1, -#ext - 1) .. ".t3x" end
    end
    for _, ext in ipairs({ ".ttf", ".otf" }) do
      if lower:sub(-#ext) == ext then return rel:sub(1, -#ext - 1) .. ".bcfnt" end
    end
    return rel
  end
  Mock.translate = translate

  local function readAll(rel)
    rel = translate(rel)
    local path = resolve(rel)
    if not path or isDir(path) then return nil, "Could not open file " .. tostring(rel) end
    local f = io.open(path, "rb")
    local data = f:read("*a")
    f:close()
    return data
  end
  Mock.readFile = readAll

  local impl = {}
  function impl.init() return true end
  function impl.setFused(v) fused = v end
  function impl.isFused() return fused end
  function impl.setIdentity(name)
    identity = name
    saveDir = saveRoot .. "/" .. identity
    os.execute("mkdir -p " .. shellQuote(saveDir))
    return true
  end
  function impl.getIdentity() return identity end
  function impl.getSaveDirectory() return saveDir end
  function impl.getSource() return sourceDir end
  function impl.getSourceBaseDirectory() return sourceDir:match("^(.*)/[^/]+$") or sourceDir end
  function impl.getWorkingDirectory() return sourceDir end
  function impl.getUserDirectory() return saveRoot end
  function impl.getExecutablePath() return sourceDir .. "/lovepotion.3dsx" end
  function impl.getRequirePath() return "?.lua;?/init.lua" end
  function impl.setRequirePath() end
  function impl.getRealDirectory(rel)
    local _, where = resolve(rel)
    if where == "save" then return saveDir end
    if where == "source" then return sourceDir end
    return nil
  end
  function impl.getInfo(rel, filterOrTable, maybeTable)
    local path = resolve(translate(rel))
    if not path then return nil end
    local info = (type(filterOrTable) == "table" and filterOrTable)
      or (type(maybeTable) == "table" and maybeTable) or {}
    if isDir(path) then
      info.type = "directory"; info.size = nil
    else
      info.type = "file"; info.size = fileSize(path)
    end
    info.modtime = 0
    if type(filterOrTable) == "string" and info.type ~= filterOrTable then return nil end
    return info
  end
  function impl.exists(rel) return resolve(rel) ~= nil end
  function impl.read(a, b, c)
    -- read(name[, size]) or read(container, name[, size])
    local container, name, size = "string", a, b
    if a == "string" or a == "data" then container, name, size = a, b, c end
    local data, err = readAll(name)
    if not data then return nil, err end
    if type(size) == "number" then data = data:sub(1, size) end
    if container == "data" then return fs.newFileData(data, name), #data end
    return data, #data
  end
  function impl.lines(rel)
    local data = readAll(rel) or ""
    return data:gmatch("([^\n]*)\n?")
  end
  function impl.load(rel)
    local data, err = readAll(rel)
    if not data then return nil, err end
    return loadstring(data, "@" .. normalize(rel))
  end
  local function writeTo(rel, data, mode)
    rel = normalize(rel)
    local dir = rel:match("^(.*)/[^/]+$")
    if dir and not isDir(savePath(dir)) then return false, "Could not set write directory." end
    if type(data) == "table" and data.getString then data = data:getString() end
    local f, err = io.open(savePath(rel), mode)
    if not f then return false, err end
    f:write(data or "")
    f:close()
    return true
  end
  function impl.write(rel, data) return writeTo(rel, data, "wb") end
  function impl.append(rel, data) return writeTo(rel, data, "ab") end
  function impl.createDirectory(rel)
    os.execute("mkdir -p " .. shellQuote(savePath(normalize(rel))))
    return true
  end
  function impl.remove(rel)
    rel = normalize(rel)
    local p = savePath(rel)
    if isDir(p) then
      if #listDir(p) > 0 then return false end
      os.execute("rmdir " .. shellQuote(p)); return true
    end
    return os.remove(p) ~= nil
  end
  function impl.getDirectoryItems(rel)
    rel = normalize(rel)
    local seen, out = {}, {}
    for _, base in ipairs({ savePath(rel), sourcePath(rel) }) do
      if isDir(base) then
        for _, name in ipairs(listDir(base)) do
          if not seen[name] then seen[name] = true; out[#out + 1] = name end
        end
      end
    end
    table.sort(out)
    return out
  end
  function impl.mount() return false end
  function impl.unmount() return false end
  function impl.mountFullPath() return false end
  function impl.unmountFullPath() return false end
  function impl.mountCommonPath() return false end
  function impl.unmountCommonPath() return false end

  function impl.newFileData(contents, name)
    if name == nil and type(contents) == "string" then
      -- newFileData(path)
      local data, err = readAll(contents)
      if not data then error(err, 2) end
      return fs.newFileData(data, contents)
    end
    if type(contents) == "table" and contents.getString then contents = contents:getString() end
    return newObject("filedata", {
      getString = function(self) return self.bytes end,
      getSize = function(self) return #self.bytes end,
      getFilename = function(self) return self.name end,
      getExtension = function(self) return (self.name:match("%.([^./]+)$") or "") end,
      clone = function(self) return fs.newFileData(self.bytes, self.name) end,
      getPointer = function() return nil end,
    }, { bytes = contents or "", name = name or "" })
  end

  function impl.openFile(rel, mode)
    rel = normalize(rel)
    local path
    if mode == "r" then
      path = resolve(rel)
      if not path then return nil, "Could not open file " .. rel .. ". Does not exist." end
    else
      path = savePath(rel)
    end
    local cmode = ({ r = "rb", w = "wb", a = "ab" })[mode] or "rb"
    local handle = io.open(path, cmode)
    if not handle then return nil, "Could not open file " .. rel end
    return newObject("file", {
      read = function(self, a, b)
        local n = type(a) == "number" and a or b
        local data = self.h:read(n or "*a") or ""
        if a == "data" then return fs.newFileData(data, rel), #data end
        return data, #data
      end,
      write = function(self, data, size)
        if type(data) == "table" and data.getString then data = data:getString() end
        if size then data = data:sub(1, size) end
        self.h:write(data); return true
      end,
      close = function(self) if self.h then self.h:close(); self.h = nil end return true end,
      isOpen = function(self) return self.h ~= nil end,
      getSize = function(self)
        local cur = self.h:seek(); local size = self.h:seek("end"); self.h:seek("set", cur)
        return size
      end,
      seek = function(self, pos) return self.h:seek("set", pos) ~= nil end,
      tell = function(self) return self.h:seek() end,
      isEOF = function(self)
        local cur = self.h:seek(); local size = self.h:seek("end"); self.h:seek("set", cur)
        return cur >= size
      end,
      flush = function(self) self.h:flush(); return true end,
      getFilename = function() return rel end,
      getMode = function() return mode end,
      lines = function(self) return self.h:lines() end,
      setBuffer = function() return true end,
      getBuffer = function() return "none", 0 end,
      open = function() return true end,
    }, { h = handle })
  end

  for name, f in pairs(impl) do
    if FUNCS.filesystem[name] then fs[name] = f end
  end
  return fs
end

---------------------------------------------------------------------------
-- images: only what the patched 3DS build decodes
---------------------------------------------------------------------------

local function be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function decodeDims(bytes, name)
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    return be32(bytes, 17), be32(bytes, 21)
  end
  if name and name:match("%.t3x$") then return 64, 64 end
  error(("Could not decode file '%s' to ImageData: unsupported file format"):format(
    tostring(name or "?")), 3)
end
Mock.decodeDims = decodeDims

---------------------------------------------------------------------------
-- the love table
---------------------------------------------------------------------------

function Mock.install(opts)
  local love = {}
  _G.love = love
  love._console = "3DS"
  love._os = "Horizon"
  love._version = "12.0"
  love._version_major, love._version_minor, love._version_revision = 12, 0, 0
  love._potion_version = "3.0.2"

  local sim = { time = 0, dt = 1 / 60, frames = 0 }
  Mock.sim = sim
  local events = {}
  Mock.events = events

  local function module(name, impl)
    local t = {}
    for fn in pairs(FUNCS[name] or {}) do
      t[fn] = impl[fn] or function() note("stubcall", name .. "." .. fn) return nil end
    end
    for fn in pairs(impl) do
      if not (FUNCS[name] or {})[fn] then
        error("mock implements love." .. name .. "." .. fn .. ", which LÖVE Potion lacks")
      end
    end
    love[name] = t
    package.loaded["love." .. name] = t
    return t
  end

  -- filesystem --------------------------------------------------------------
  local fs = Mock.newFilesystem(opts.source, opts.saveRoot)
  love.filesystem = fs
  package.loaded["love.filesystem"] = fs
  fs.setIdentity("lovepotion")

  -- timer --------------------------------------------------------------------
  module("timer", {
    getTime = function() return sim.time end,
    getDelta = function() return sim.dt end,
    getAverageDelta = function() return sim.dt end,
    getFPS = function() return 60 end,
    step = function() return sim.dt end,
    sleep = function() end,
  })

  -- event --------------------------------------------------------------------
  module("event", {
    pump = function() end,
    poll = function()
      return function()
        local e = table.remove(events, 1)
        if e then return unpack(e, 1, 7) end
      end
    end,
    push = function(...) events[#events + 1] = { ... } end,
    quit = function(code) events[#events + 1] = { "quit", code } end,
    clear = function() for i = #events, 1, -1 do events[i] = nil end end,
    wait = function() return table.remove(events, 1) end,
  })

  -- system -------------------------------------------------------------------
  module("system", {
    getOS = function() return "Horizon" end,
    getModel = function() return "New 3DS XL" end,
    getProcessorCount = function() return 2 end,
    getPowerInfo = function() return "battery", 80, nil end,
    getPreferredLocales = function() return { "en_US" } end,
    getVersion = function() return "11.17.0-50U" end,
    getNetworkInfo = function() return "wifi", 3 end,
    getColorTheme = function() return "dark" end,
    getFriendInfo = function() return "Player", "0000-0000-0000" end,
    getPlayCoins = function() return 0 end,
  })

  -- graphics -----------------------------------------------------------------
  local screens = { left = { 400, 240 }, right = { 400, 240 }, bottom = { 320, 240 } }
  local gstate = {
    screen = "left", color = { 1, 1, 1, 1 }, bg = { 0, 0, 0, 1 },
    canvas = nil, font = nil, stack = {}, lineWidth = 1, blend = "alpha",
    scissor = nil, enabled3D = true, filter = { "linear", "linear", 1 },
    draws = 0, perScreenDraws = {}, presents = 0,
  }
  Mock.gstate = gstate

  local function texture(w, h, extra)
    return newObject("texture", {
      getWidth = function(self) return self.w end,
      getHeight = function(self) return self.h end,
      getDimensions = function(self) return self.w, self.h end,
      getPixelWidth = function(self) return self.w end,
      getPixelHeight = function(self) return self.h end,
      getPixelDimensions = function(self) return self.w, self.h end,
      getDPIScale = function() return 1 end,
      getFilter = function(self) return self.fmin or "linear", self.fmag or "linear", 1 end,
      setFilter = function(self, a, b) self.fmin, self.fmag = a, b or a end,
      getWrap = function(self) return self.wh or "clamp", self.wv or "clamp" end,
      setWrap = function(self, a, b) self.wh, self.wv = a, b or a end,
      isRenderTarget = function(self) return self.canvas == true end,
      isReadable = function() return true end,
      getFormat = function() return "rgba8" end,
      getTextureType = function() return "2d" end,
      getMipmapCount = function() return 1 end,
      getLayerCount = function() return 1 end,
      getDepth = function() return 1 end,
      getMSAA = function() return 1 end,
      replacePixels = function() end,
      renderTo = function(self, fn, ...)
        local prev = gstate.canvas
        gstate.canvas = self
        fn(...)
        gstate.canvas = prev
      end,
    }, extra or { w = w, h = h })
  end

  local function newFont(size)
    size = size or 12
    return newObject("font", {
      getHeight = function(self) return self.size end,
      getWidth = function(self, text) return #tostring(text) * math.floor(self.size * 0.6 + 0.5) end,
      getLineHeight = function() return 1 end,
      setLineHeight = function() end,
      getBaseline = function(self) return self.size end,
      getAscent = function(self) return self.size end,
      getDescent = function() return 0 end,
      getDPIScale = function() return 1 end,
      getFilter = function() return "linear", "linear", 1 end,
      setFilter = function() end,
      hasGlyphs = function() return true end,
      setFallbacks = function() end,
      getKerning = function() return 0 end,
      getWrap = function(self, text, limit)
        text = tostring(text or "")
        local per = math.max(1, math.floor((limit or 1e9) / math.max(1, math.floor(self.size * 0.6 + 0.5))))
        local lines = {}
        for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
          if #raw == 0 then lines[#lines + 1] = "" end
          local i = 1
          while i <= #raw do lines[#lines + 1] = raw:sub(i, i + per - 1); i = i + per end
        end
        local width = 0
        for _, l in ipairs(lines) do width = math.max(width, #l * math.floor(self.size * 0.6 + 0.5)) end
        return width, lines
      end,
    }, { size = size })
  end
  gstate.font = newFont(12)

  local function imagedata(w, h, bytes)
    local px = {}
    return newObject("imagedata", {
      getWidth = function(self) return self.w end,
      getHeight = function(self) return self.h end,
      getDimensions = function(self) return self.w, self.h end,
      getFormat = function() return "rgba8" end,
      getPixel = function(self, x, y)
        if x < 0 or y < 0 or x >= self.w or y >= self.h then
          error("Attempt to get out-of-range pixel!", 2)
        end
        local p = px[y * self.w + x]
        if p then return p[1], p[2], p[3], p[4] end
        return 0, 0, 0, 0
      end,
      setPixel = function(self, x, y, r, g, b, a)
        if type(r) == "table" then r, g, b, a = r[1], r[2], r[3], r[4] end
        if x < 0 or y < 0 or x >= self.w or y >= self.h then
          error("Attempt to set out-of-range pixel!", 2)
        end
        px[y * self.w + x] = { r, g, b, a or 1 }
      end,
      mapPixel = function(self, fn, sx, sy, sw, sh)
        sx, sy = sx or 0, sy or 0
        sw, sh = sw or self.w, sh or self.h
        for y = sy, sy + sh - 1 do
          for x = sx, sx + sw - 1 do
            local p = px[y * self.w + x] or { 0, 0, 0, 0 }
            local r, g, b, a = fn(x, y, p[1], p[2], p[3], p[4])
            px[y * self.w + x] = { r, g, b, a }
          end
        end
      end,
      paste = function() end,
      clone = function(self) return imagedata(self.w, self.h) end,
      encode = function(self, format)
        return fs.newFileData("\137PNG\r\n\26\n" .. string.rep("\0", 8)
          .. string.char(0, 0, math.floor(self.w / 256), self.w % 256,
                         0, 0, math.floor(self.h / 256), self.h % 256), "encoded." .. (format or "png"))
      end,
      getString = function(self) return string.rep("\0", self.w * self.h * 4) end,
      getSize = function(self) return self.w * self.h * 4 end,
      getPointer = function() return nil end,
    }, { w = w, h = h })
  end
  Mock.imagedata = imagedata

  local function imageSource(src)
    if type(src) == "string" then
      local bytes = Mock.readFile(src)
      if not bytes then error("Could not open file " .. src .. ". Does not exist.", 3) end
      local w, h = decodeDims(bytes, src)
      return w, h
    end
    if type(src) == "table" then
      if src.typeOf and src:typeOf("ImageData") then return src:getWidth(), src:getHeight() end
      if src.typeOf and src:typeOf("FileData") then return decodeDims(src:getString(), src:getFilename()) end
    end
    error("Could not decode image source", 3)
  end

  local function dims()
    if gstate.canvas then return gstate.canvas.w, gstate.canvas.h end
    local s = screens[gstate.screen]
    return s[1], s[2]
  end

  local function drawn()
    gstate.draws = gstate.draws + 1
    if not gstate.canvas then
      gstate.perScreenDraws[gstate.screen] = (gstate.perScreenDraws[gstate.screen] or 0) + 1
    end
  end

  local g = {
    getDimensions = function() return dims() end,
    getWidth = function() local w = dims() return w end,
    getHeight = function() local _, h = dims() return h end,
    getPixelDimensions = function() return dims() end,
    getPixelWidth = function() local w = dims() return w end,
    getPixelHeight = function() local _, h = dims() return h end,
    getScreens = function()
      if gstate.enabled3D then return { "left", "right", "bottom" } end
      return { "left", "bottom" }
    end,
    setActiveScreen = function(name)
      assert(screens[name], "Invalid screen: " .. tostring(name))
      gstate.screen = name
    end,
    get3D = function() return gstate.enabled3D end,
    set3D = function(v) gstate.enabled3D = v and true or false end,
    getDepth = function() return 0 end,
    isActive = function() return true end,
    isCreated = function() return true end,
    present = function() gstate.presents = gstate.presents + 1 end,
    clear = function() end,
    origin = function() end,
    reset = function() gstate.color = { 1, 1, 1, 1 }; gstate.canvas = nil end,
    push = function() gstate.stack[#gstate.stack + 1] = {
      color = { unpack(gstate.color) }, canvas = gstate.canvas, font = gstate.font,
      scissor = gstate.scissor, lineWidth = gstate.lineWidth, blend = gstate.blend } end,
    pop = function()
      local top = table.remove(gstate.stack)
      if not top then error("Minimum stack depth reached (more pops than pushes?)", 2) end
      gstate.color, gstate.canvas, gstate.font = top.color, top.canvas, top.font
      gstate.scissor, gstate.lineWidth, gstate.blend = top.scissor, top.lineWidth, top.blend
    end,
    translate = function() end, rotate = function() end, scale = function() end,
    shear = function() end, applyTransform = function() end, replaceTransform = function() end,
    transformPoint = function(x, y) return x, y end,
    inverseTransformPoint = function(x, y) return x, y end,
    setColor = function(r, g2, b, a)
      if type(r) == "table" then r, g2, b, a = r[1], r[2], r[3], r[4] end
      gstate.color = { r or 1, g2 or 1, b or 1, a or 1 }
    end,
    getColor = function() return unpack(gstate.color) end,
    setBackgroundColor = function(r, g2, b, a)
      if type(r) == "table" then r, g2, b, a = r[1], r[2], r[3], r[4] end
      gstate.bg = { r or 0, g2 or 0, b or 0, a or 1 }
    end,
    getBackgroundColor = function() return unpack(gstate.bg) end,
    setCanvas = function(c)
      if type(c) == "table" and not (c.typeOf and c:typeOf("Texture")) then c = c[1] end
      gstate.canvas = c
    end,
    getCanvas = function() return gstate.canvas end,
    setFont = function(f) gstate.font = f end,
    getFont = function() return gstate.font end,
    -- The 3DS rasterizer only reads CFNT (.bcfnt) and does not check: any
    -- other bytes are parsed as CFNT and crash the console.
    newFont = function(a, b)
      if a == nil or type(a) == "number" then return newFont(a or 12) end
      local bytes, name
      if type(a) == "string" then
        bytes = Mock.readFile(a)
        if not bytes then error("Could not open file " .. Mock.translate(a) .. ". Does not exist.", 2) end
        name = a
      elseif type(a) == "table" and a.getString then
        bytes, name = a:getString(), "<data>"
      end
      if bytes and bytes:sub(1, 4) ~= "CFNT" then
        error("CONSOLE CRASH: non-CFNT font data (" .. tostring(name) .. ") passed to the 3DS font rasterizer", 2)
      end
      return newFont(type(b) == "number" and b or 12)
    end,
    setDefaultFilter = function(a, b, c) gstate.filter = { a, b or a, c or 1 } end,
    getDefaultFilter = function() return unpack(gstate.filter) end,
    setLineWidth = function(w) gstate.lineWidth = w end,
    getLineWidth = function() return gstate.lineWidth end,
    setLineStyle = function() end, getLineStyle = function() return "smooth" end,
    setLineJoin = function() end, getLineJoin = function() return "miter" end,
    setBlendMode = function(m) gstate.blend = m end,
    getBlendMode = function() return gstate.blend, "alphamultiply" end,
    setScissor = function(x, y, w, h) gstate.scissor = x and { x, y, w, h } or nil end,
    intersectScissor = function(x, y, w, h) gstate.scissor = { x, y, w, h } end,
    getScissor = function() if gstate.scissor then return unpack(gstate.scissor) end end,
    setColorMask = function() end, getColorMask = function() return true, true, true, true end,
    getStats = function() return { drawcalls = gstate.draws, canvasswitches = 0,
      texturememory = 0, images = 0, canvases = 0, fonts = 1, shaderswitches = 0,
      drawcallsbatched = 0 } end,
    getRendererInfo = function() return "OpenGL", "citro3d", "DMP", "PICA200" end,
    draw = function() drawn() end,
    print = function() drawn() end,
    printf = function() drawn() end,
    rectangle = function() drawn() end,
    line = function() drawn() end,
    points = function() drawn() end,
    polygon = function() drawn() end,
    circle = function() drawn() end,
    ellipse = function() drawn() end,
    arc = function() drawn() end,
    newCanvas = function(w, h)
      local W, H = dims()
      w, h = w or W, h or H
      if w > 1024 or h > 1024 then
        error(("Cannot create a %dx%d canvas: the 3DS GPU tops out at 1024x1024"):format(w, h), 2)
      end
      return texture(w, h, { w = w, h = h, canvas = true })
    end,
    newImage = function(src)
      local w, h = imageSource(src)
      if w > 1024 or h > 1024 then
        error(("Cannot load a %dx%d texture: the 3DS GPU tops out at 1024x1024"):format(w, h), 2)
      end
      return texture(w, h)
    end,
    newTexture = function(src) local w, h = imageSource(src) return texture(w, h) end,
    newQuad = function(x, y, w, h, sw, sh)
      if type(sw) == "table" then sw, sh = sw:getDimensions() end
      return newObject("quad", {
        getViewport = function(self) return self.x, self.y, self.w, self.h end,
        setViewport = function(self, a, b, c, d) self.x, self.y, self.w, self.h = a, b, c, d end,
        getTextureDimensions = function(self) return self.sw, self.sh end,
        getLayer = function() return 1 end, setLayer = function() end,
      }, { x = x, y = y, w = w, h = h, sw = sw, sh = sh })
    end,
    newSpriteBatch = function(tex, size)
      return newObject("spritebatch", {
        add = function(self) self.count = self.count + 1 return self.count end,
        set = function() end,
        clear = function(self) self.count = 0 end,
        flush = function() end,
        getCount = function(self) return self.count end,
        getBufferSize = function(self) return self.size end,
        getTexture = function(self) return self.tex end,
        setTexture = function(self, t) self.tex = t end,
        setColor = function() end, getColor = function() return 1, 1, 1, 1 end,
        setDrawRange = function() end, getDrawRange = function() return 1, 1 end,
      }, { tex = tex, size = size or 1000, count = 0 })
    end,
    newTextBatch = function(font)
      return newObject("textbatch", {}, { font = font })
    end,
    newMesh = function() Mock.meshes = (Mock.meshes or 0) + 1 return newObject("mesh", {}, {}) end,
    getMeshCullMode = function() return "none" end, setMeshCullMode = function() end,
    getFrontFaceWinding = function() return "ccw" end, setFrontFaceWinding = function() end,
    getBlendState = function() return {} end, setBlendState = function() end,
  }
  module("graphics", g)
  -- Lua-side additions LÖVE Potion makes in include/scripts/wrap_graphics.lua
  love.graphics.newVideo = function() error("Video is not supported on this platform", 2) end

  -- image --------------------------------------------------------------------
  module("image", {
    newImageData = function(a, b)
      if type(a) == "number" then return imagedata(a, b) end
      local w, h = imageSource(a)
      return imagedata(w, h)
    end,
    isCompressed = function() return false end,
  })

  -- font ---------------------------------------------------------------------
  module("font", {})

  -- window -------------------------------------------------------------------
  module("window", {
    isOpen = function() return true end,
    -- LÖVE Potion rebuilds every screen framebuffer here; count calls so the
    -- harness can insist the game never does it after boot
    setMode = function() Mock.setModeCalls = (Mock.setModeCalls or 0) + 1 return true end,
    setTitle = function() end,
    setIcon = function() return true end,
  })
  love.window.showMessageBox = function() return 1 end

  -- audio / sound ------------------------------------------------------------
  local function sounddata(samples, rate, bits, channels)
    local store = {}
    return newObject("sounddata", {
      getSampleCount = function(self) return self.samples end,
      getSampleRate = function(self) return self.rate end,
      getBitDepth = function(self) return self.bits end,
      getChannelCount = function(self) return self.channels end,
      getDuration = function(self) return self.samples / self.rate end,
      getSample = function(self, i, ch) return store[(i * self.channels) + ((ch or 1) - 1)] or 0 end,
      setSample = function(self, i, a, b)
        local ch, v = 1, a
        if b ~= nil then ch, v = a, b end
        if i < 0 or i >= self.samples then error("Attempt to set out-of-range sample!", 2) end
        store[(i * self.channels) + (ch - 1)] = v
      end,
      getSize = function(self) return self.samples * self.channels * self.bits / 8 end,
      getString = function(self) return string.rep("\0", self:getSize()) end,
      getPointer = function() return nil end,
      clone = function(self) return sounddata(self.samples, self.rate, self.bits, self.channels) end,
    }, { samples = samples, rate = rate or 44100, bits = bits or 16, channels = channels or 2 })
  end

  module("sound", {
    newSoundData = function(a, rate, bits, ch)
      if type(a) == "number" then return sounddata(a, rate, bits, ch) end
      return sounddata(44100, 44100, 16, 2)
    end,
    newDecoder = function() return newObject("decoder", {}, {}) end,
  })

  Mock.audio = { queued = 0, plays = 0, queueSources = 0 }
  local function source(kind, fmt)
    return newObject("source", {
      play = function(self) self.playing = true; Mock.audio.plays = Mock.audio.plays + 1; return true end,
      stop = function(self) self.playing = false end,
      pause = function(self) self.playing = false end,
      isPlaying = function(self) return self.playing == true end,
      setVolume = function(self, v) self.volume = v end,
      getVolume = function(self) return self.volume or 1 end,
      setLooping = function(self, v)
        if self.kind == "queue" then error("Queueable Sources can not be looped.", 2) end
        self.looping = v
      end,
      isLooping = function(self) return self.looping == true end,
      getType = function(self) return self.kind end,
      getChannelCount = function(self) return self.fmt and self.fmt.channels or 2 end,
      getFreeBufferCount = function(self)
        if self.kind ~= "queue" then return 0 end
        return self.fmt.buffers - self.inQueue
      end,
      queue = function(self, sd)
        if self.kind ~= "queue" then error("Only queueable Sources can be queued with sound data.", 2) end
        if sd:getSampleRate() ~= self.fmt.rate or sd:getChannelCount() ~= self.fmt.channels
           or sd:getBitDepth() ~= self.fmt.bits then
          error("Queued sound data must have same format as sound Source.", 2)
        end
        if self.inQueue >= self.fmt.buffers then return false end
        self.inQueue = self.inQueue + 1
        Mock.audio.queued = Mock.audio.queued + 1
        return true
      end,
      seek = function() end, tell = function() return 0 end,
      getDuration = function() return 0 end,
      setVolumeLimits = function() end, getVolumeLimits = function() return 0, 1 end,
      clone = function(self) return source(self.kind, self.fmt) end,
    }, { kind = kind, fmt = fmt, inQueue = 0 })
  end
  Mock.drainAudio = function(src) if src and src.inQueue then src.inQueue = 0 end end

  module("audio", {
    newSource = function(src, kind)
      if kind == "queue" then
        error("Cannot create queueable sources using newSource. Use newQueueableSource instead.", 2)
      end
      if type(src) == "string" and not Mock.resolvePath(src) then
        error("Could not open file " .. src .. ". Does not exist.", 2)
      end
      return source(kind or "stream")
    end,
    -- registered by the LÖVE Potion patch in this fork
    newQueueableSource = function(rate, bits, channels, buffers)
      Mock.audio.queueSources = Mock.audio.queueSources + 1
      buffers = (buffers and buffers > 0) and math.min(buffers, 64) or 8
      return source("queue", { rate = rate, bits = bits, channels = channels, buffers = buffers })
    end,
    setVolume = function(v) Mock.audio.volume = v end,
    getVolume = function() return Mock.audio.volume or 1 end,
    play = function() return true end, pause = function() return {} end, stop = function() end,
    getActiveSourceCount = function() return 0 end,
  })
  if opts.unpatchedPotion then
    love.audio.newQueueableSource = nil -- stock 3.0.2: never registered
  end

  -- data ---------------------------------------------------------------------
  module("data", {
    newByteData = function(a)
      local bytes = type(a) == "number" and string.rep("\0", a) or tostring(a or "")
      return newObject("bytedata", {
        getString = function(self) return self.bytes end,
        getSize = function(self) return #self.bytes end,
        getPointer = function() return nil end,
        clone = function(self) return love.data.newByteData(self.bytes) end,
      }, { bytes = bytes })
    end,
    -- love.data.hash(function, data), LÖVE 11 order, as LÖVE Potion takes it
    hash = function(fn, data)
      local len = ({ md5 = 16, sha1 = 20, sha224 = 28, sha256 = 32, sha384 = 48, sha512 = 64 })[fn]
      if not len then error("Invalid hash function '" .. tostring(fn) .. "'", 2) end
      if type(data) ~= "string" and not (type(data) == "table" and data.getString) then
        error("bad argument #2 to 'hash' (Data expected)", 2)
      end
      return string.rep("\0", len)
    end,
    encode = function(container, format, data)
      if type(data) == "table" then data = data:getString() end
      if format == "hex" then
        return (tostring(data):gsub(".", function(c) return ("%02x"):format(c:byte()) end))
      end
      return tostring(data)
    end,
    decode = function(_, _, data) return data end,
    compress = function(_, _, data) return data end,
    decompress = function(_, _, data) return data end,
    pack = function(_, fmt, ...) return "" end,
    unpack = function() return nil end,
    getPackedSize = function() return 0 end,
  })

  -- math ---------------------------------------------------------------------
  local function rng()
    return newObject("randomgenerator", {
      random = function(_, a, b)
        if a == nil then return math.random() end
        if b == nil then return math.random(a) end
        return math.random(a, b)
      end,
      randomNormal = function(_, sd, mean) return (mean or 0) end,
      setSeed = function() end, getSeed = function() return 0, 0 end,
      setState = function() end, getState = function() return "0x0" end,
    }, {})
  end
  module("math", {
    random = function(a, b)
      if a == nil then return math.random() end
      if b == nil then return math.random(a) end
      return math.random(a, b)
    end,
    randomNormal = function(sd, mean) return mean or 0 end,
    setRandomSeed = function(s) math.randomseed(tonumber(s) or 0) end,
    getRandomSeed = function() return 0, 0 end,
    setRandomState = function() end,
    getRandomState = function() return "0x0" end,
    newRandomGenerator = function() return rng() end,
    colorToBytes = function(r, g2, b, a)
      return math.floor(r * 255 + .5), math.floor(g2 * 255 + .5), math.floor(b * 255 + .5),
        a and math.floor(a * 255 + .5)
    end,
    colorFromBytes = function(r, g2, b, a) return r / 255, g2 / 255, b / 255, a and a / 255 end,
    gammaToLinear = function(...) return ... end,
    linearToGamma = function(...) return ... end,
    newTransform = function() return newObject("transform", {}, {}) end,
    noise = nil,
  })

  -- thread -------------------------------------------------------------------
  local channels = {}
  local function channel()
    local q = {}
    return newObject("channel", {
      push = function(_, v) q[#q + 1] = v; return #q end,
      supply = function(_, v) q[#q + 1] = v; return true end,
      pop = function() return table.remove(q, 1) end,
      demand = function() return table.remove(q, 1) end,
      peek = function() return q[1] end,
      getCount = function() return #q end,
      clear = function() for i = #q, 1, -1 do q[i] = nil end end,
      hasRead = function() return true end,
      performAtomic = function(self, fn, ...) return fn(self, ...) end,
    }, {})
  end
  Mock.threads = {}
  module("thread", {
    newThread = function(path)
      if type(path) == "string" and not path:find("\n") and not Mock.resolvePath(path) then
        error("Could not open file " .. path .. ". Does not exist.", 2)
      end
      local t = newObject("luathread", {
        start = function(self) self.started = true end,
        wait = function() end,
        isRunning = function(self) return self.started == true end,
        getError = function() return nil end,
      }, { path = path })
      Mock.threads[#Mock.threads + 1] = t
      return t
    end,
    newChannel = function() return channel() end,
    getChannel = function(name)
      channels[name] = channels[name] or channel()
      return channels[name]
    end,
  })

  -- joystick: the 3DS's built-in pad ----------------------------------------
  local held = {}
  Mock.held = held
  local pad = newObject("joystick", {
    isGamepad = function() return true end,
    isConnected = function() return true end,
    getName = function() return "Nintendo 3DS" end,
    getID = function() return 1, 1 end,
    getGUID = function() return "3ds" end,
    getConnectedIndex = function() return 1 end,
    isGamepadDown = function(_, ...)
      for _, b in ipairs({ ... }) do if held[b] then return true end end
      return false
    end,
    isDown = function() return false end,
    getButtonCount = function() return 14 end,
    getAxisCount = function() return 6 end,
    getAxis = function() return 0 end,
    getAxes = function() return 0, 0, 0, 0, 0, 0 end,
    getGamepadAxis = function() return 0 end,
    getHatCount = function() return 0 end,
    getHat = function() return "c" end,
    getGamepadType = function() return "nintendo3ds" end,
    isVibrationSupported = function() return false end,
    setVibration = function() return false end,
    getVibration = function() return 0, 0 end,
    getDeviceInfo = function() return 0, 0, 0 end,
    getPlayerIndex = function() return 1 end,
    setPlayerIndex = function() end,
    hasSensor = function() return false end,
  }, {})
  Mock.pad = pad
  module("joystick", {
    getJoysticks = function() return { pad } end,
    getJoystickCount = function() return 1 end,
    getIndex = function() return 1 end,
  })

  module("keyboard", {
    hasTextInput = function() return false end,
    setTextInput = function() end,
    hasScreenKeyboard = function() return true end,
  })
  module("touch", { getTouches = function() return {} end })
  module("sensor", { hasSensor = function() return false end, isEnabled = function() return false end })

  -- arg / handlers (LÖVE Potion's arg.lua and callbacks.lua) -----------------
  love.arg = {
    parseGameArguments = function(a)
      local out = {}
      for i, v in ipairs(a or {}) do out[i] = v end
      return out
    end,
    options = {},
  }
  love.handlers = setmetatable({}, {
    __index = function(_, name)
      return function(...) local f = love[name] if f then return f(...) end end
    end,
  })

  return love
end

---------------------------------------------------------------------------
-- input helpers
---------------------------------------------------------------------------

function Mock.press(button)
  Mock.held[button] = true
  Mock.events[#Mock.events + 1] = { "gamepadpressed", Mock.pad, button }
end

function Mock.release(button)
  Mock.held[button] = nil
  Mock.events[#Mock.events + 1] = { "gamepadreleased", Mock.pad, button }
end

function Mock.touch(x, y)
  Mock.events[#Mock.events + 1] = { "touchpressed", "t1", x, y, 0, 0, 1 }
  Mock.events[#Mock.events + 1] = { "touchreleased", "t1", x, y, 0, 0, 1 }
end

return Mock
