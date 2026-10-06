-- Count what Gen1Recomp does before its first frame on the 3DS mock.
local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = HERE .. "/?.lua;" .. package.path
local Mock = require("lovepotion_mock")
local gameDir, saveRoot = arg[1], arg[2]
os.execute("mkdir -p '" .. saveRoot .. "'")
Mock.install({ source = gameDir, saveRoot = saveRoot })
package.path = gameDir .. "/?.lua;" .. gameDir .. "/?/init.lua;" .. package.path
print = function() end
local stats = { modules = 0, srcBytes = 0, reads = 0, readBytes = 0, images = {}, fonts = 0 }
-- source bytes per required module
local realRequire = require
local seen = {}
local function modfile(name)
  local p = name:gsub("%.", "/")
  for _, c in ipairs({ gameDir .. "/" .. p .. ".lua", gameDir .. "/" .. p .. "/init.lua" }) do
    local f = io.open(c, "rb"); if f then local n = f:seek("end"); f:close(); return c, n end
  end
end
local byDir = {}
require = function(name)
  if not package.loaded[name] and not seen[name] then
    seen[name] = true
    local path, n = modfile(name)
    if path then
      stats.modules = stats.modules + 1; stats.srcBytes = stats.srcBytes + n
      local dir = name:match("^(src%.[%w_]+%.?[%w_]*)") or name
      local top = name:match("^src%.([%w_]+)") or name
      byDir[top] = (byDir[top] or 0) + n
      stats.list = stats.list or {}
      stats.list[#stats.list + 1] = { name, n, debug.traceback("", 3) }
    end
  end
  return realRequire(name)
end
local fs = love.filesystem
for _, fn in ipairs({ "read", "newFileData", "lines", "load" }) do
  local f = fs[fn]
  fs[fn] = function(p, ...)
    local r1, r2 = f(p, ...)
    stats.reads = stats.reads + 1
    local rel = type(p) == "string" and p or (select(1, ...))
    return r1, r2
  end
end
local g = love.graphics
local ni = g.newImage
g.newImage = function(src, ...)
  local img = ni(src, ...)
  if type(src) == "string" then
    local w, h = img:getDimensions()
    stats.images[#stats.images + 1] = { src, w * h }
  end
  return img
end
local nid = love.image.newImageData
love.image.newImageData = function(a, ...)
  local d = nid(a, ...)
  if type(a) == "string" then
    stats.images[#stats.images + 1] = { a .. " (ImageData)", d:getWidth() * d:getHeight() }
  end
  return d
end
local nf = g.newFont
g.newFont = function(...) stats.fonts = stats.fonts + 1 return nf(...) end

local c = { window = {}, modules = { mouse = false }, audio = {} }
assert(loadfile(gameDir .. "/conf.lua"))(); love.conf(c)
for k, v in pairs(c.modules) do if v == false then love[k] = nil end end
if c.identity then fs.setIdentity(c.identity) end
local t0 = os.clock()
assert(loadfile(gameDir .. "/main.lua"))()
local loop = love.run()
local t1 = os.clock()
local atLoad = { modules = stats.modules, srcBytes = stats.srcBytes, images = #stats.images }
Mock.sim.time = Mock.sim.time + 1/60
loop()
local t2 = os.clock()
io.write(("love.load: %d modules, %.2f MB of Lua source, %d images; host CPU %.2fs\n"):format(
  atLoad.modules, atLoad.srcBytes / 1e6, atLoad.images, t1 - t0))
io.write(("after first frame: %d modules, %.2f MB source, %d images, %d fonts; host CPU %.2fs\n"):format(
  stats.modules, stats.srcBytes / 1e6, #stats.images, stats.fonts, t2 - t0))
local tops = {}
for k, v in pairs(byDir) do tops[#tops + 1] = { k, v } end
table.sort(tops, function(a, b) return a[2] > b[2] end)
io.write("source by area: ")
for i = 1, math.min(12, #tops) do io.write(("%s %.0fK  "):format(tops[i][1], tops[i][2] / 1e3)) end
io.write("\n")
table.sort(stats.list, function(a, b) return a[2] > b[2] end)
for i = 1, 25 do local m = stats.list[i]; io.write(("%7.0fK %s\n"):format(m[2] / 1e3, m[1])) end
for _, m in ipairs(stats.list) do
  if m[1]:find("syms.emerald$") or m[1]:find("versions_text_emerald") or m[1] == "src.mods.Schemas" or m[1]:find("asset_catalog") then
    io.write("== chain for " .. m[1] .. "\n")
    for line in m[3]:gmatch("[^\n]+") do
      local file, ln = line:match("gen1recomp/([%w_/%.]+%.lua):(%d+)")
      if file then io.write("   " .. file .. ":" .. ln .. "\n") end
    end
  end
end
table.sort(stats.images, function(a, b) return a[2] > b[2] end)
local px = 0
for _, im in ipairs(stats.images) do px = px + im[2] end
io.write(("decoded image pixels: %.1f M\n"):format(px / 1e6))
for i = 1, math.min(10, #stats.images) do io.write(("  %7d px  %s\n"):format(stats.images[i][2], stats.images[i][1])) end
