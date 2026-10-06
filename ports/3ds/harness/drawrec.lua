-- Records what the game draws to the 3DS screens, for rendering previews.
--
-- Wraps the mock's love.graphics after Mock.install: keeps its own 2D affine
-- transform stack in step with push/pop, and for every draw call that lands
-- on a screen (no canvas bound) stores a screen-space record, tagged top or bottom: filled or
-- outlined rectangles, polygons, lines, circles, text (with font size,
-- wrap limit and alignment) and images (with the source path and quad).
-- render_shot.py turns a recorded frame into a PNG.
--
-- It approximates, it does not emulate: text uses a monospaced stand-in for
-- the 3DS system font, canvases are not composited, and blend modes are
-- ignored.  It is for judging layout -- what fits, what overflows, where the
-- focus is -- not pixel colour.

local Rec = {}
Rec.frame = {}
Rec.last = {}

local M = { 1, 0, 0, 1, 0, 0 } -- a b c d e f : x' = a x + c y + e, y' = b x + d y + f
local stack = {}
local scissor = nil
local scissorStack = {}

local function apply(x, y)
  return M[1] * x + M[3] * y + M[5], M[2] * x + M[4] * y + M[6]
end

local function mul(a, b) -- a * b
  return {
    a[1] * b[1] + a[3] * b[2], a[2] * b[1] + a[4] * b[2],
    a[1] * b[3] + a[3] * b[4], a[2] * b[3] + a[4] * b[4],
    a[1] * b[5] + a[3] * b[6] + a[5], a[2] * b[5] + a[4] * b[6] + a[6],
  }
end

local function scaleOf() return math.sqrt(M[1] * M[1] + M[2] * M[2]) end

-- which screen a draw lands on: "top", "bottom", or nil (a canvas)
local function screenOf()
  local g = love.graphics
  if g.getCanvas() ~= nil then return nil end
  local Mock = package.loaded["lovepotion_mock"]
  local s = Mock and Mock.gstate.screen or "left"
  if s == "bottom" then return "bottom" end
  if s == "left" or s == "top" then return "top" end
  return nil
end

local function color()
  local r, g, b, a = love.graphics.getColor()
  return { r, g, b, a }
end

local function push(op)
  local screen = screenOf()
  if not screen then return end
  op.screen = screen
  op.color = op.color or color()
  op.scissor = scissor
  Rec.frame[#Rec.frame + 1] = op
end

function Rec.install()
  local g = love.graphics
  local real = {}
  for _, k in ipairs({ "origin", "push", "pop", "translate", "scale", "rotate",
      "setScissor", "intersectScissor", "rectangle", "print", "printf", "draw",
      "line", "polygon", "circle", "present", "newImage", "replaceTransform" }) do
    real[k] = g[k]
  end

  g.origin = function(...) M = { 1, 0, 0, 1, 0, 0 } return real.origin(...) end
  g.push = function(...)
    stack[#stack + 1] = { M = { unpack(M) } }
    scissorStack[#scissorStack + 1] = scissor
    return real.push(...)
  end
  g.pop = function(...)
    local top = table.remove(stack)
    if top then M = top.M end
    scissor = table.remove(scissorStack)
    return real.pop(...)
  end
  g.translate = function(x, y, ...)
    M = mul(M, { 1, 0, 0, 1, x or 0, y or 0 })
    return real.translate(x, y, ...)
  end
  g.scale = function(sx, sy, ...)
    sx = sx or 1
    M = mul(M, { sx, 0, 0, sy or sx, 0, 0 })
    return real.scale(sx, sy, ...)
  end
  g.rotate = function(r, ...)
    local c, s = math.cos(r or 0), math.sin(r or 0)
    M = mul(M, { c, s, -s, c, 0, 0 })
    return real.rotate(r, ...)
  end
  g.setScissor = function(x, y, w, h)
    scissor = x and { x, y, w, h } or nil
    return real.setScissor(x, y, w, h)
  end
  g.intersectScissor = function(x, y, w, h)
    if scissor then
      local x0 = math.max(x, scissor[1]); local y0 = math.max(y, scissor[2])
      local x1 = math.min(x + w, scissor[1] + scissor[3])
      local y1 = math.min(y + h, scissor[2] + scissor[4])
      scissor = { x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0) }
    else
      scissor = { x, y, w, h }
    end
    return real.intersectScissor(x, y, w, h)
  end

  g.rectangle = function(mode, x, y, w, h, rx, ...)
    local x0, y0 = apply(x, y)
    local x1, y1 = apply(x + w, y + h)
    push({ op = "rect", mode = mode, x0 = math.min(x0, x1), y0 = math.min(y0, y1),
      x1 = math.max(x0, x1), y1 = math.max(y0, y1), r = (rx or 0) * scaleOf(),
      lw = love.graphics.getLineWidth() * scaleOf() })
    return real.rectangle(mode, x, y, w, h, rx, ...)
  end
  g.polygon = function(mode, ...)
    local pts = select("#", ...) == 1 and ... or { ... }
    local out = {}
    for i = 1, #pts - 1, 2 do
      local px, py = apply(pts[i], pts[i + 1])
      out[#out + 1] = px; out[#out + 1] = py
    end
    push({ op = "poly", mode = mode, pts = out, lw = love.graphics.getLineWidth() * scaleOf() })
    return real.polygon(mode, ...)
  end
  g.line = function(...)
    local pts = select("#", ...) == 1 and ... or { ... }
    local out = {}
    for i = 1, #pts - 1, 2 do
      local px, py = apply(pts[i], pts[i + 1])
      out[#out + 1] = px; out[#out + 1] = py
    end
    push({ op = "line", pts = out, lw = love.graphics.getLineWidth() * scaleOf() })
    return real.line(...)
  end
  g.circle = function(mode, x, y, r, ...)
    local cx, cy = apply(x, y)
    push({ op = "circle", mode = mode, x = cx, y = cy, r = r * scaleOf() })
    return real.circle(mode, x, y, r, ...)
  end

  local function textOp(kind, text, x, y, limit, align, r, sx, sy)
    if type(text) == "table" then -- coloured text {color, string, ...}
      local parts = {}
      for i = 2, #text, 2 do parts[#parts + 1] = tostring(text[i]) end
      text = table.concat(parts)
    end
    local font = love.graphics.getFont()
    local px, py = apply(x or 0, y or 0)
    local s = scaleOf() * (sx or 1)
    push({ op = "text", text = tostring(text), x = px, y = py,
      size = (font and font.size or 12) * s, limit = limit and limit * s or nil,
      align = align or "left" })
  end
  g.print = function(text, x, y, r, sx, sy, ...)
    textOp("print", text, x, y, nil, nil, r, sx, sy)
    return real.print(text, x, y, r, sx, sy, ...)
  end
  g.printf = function(text, x, y, limit, align, r, sx, sy, ...)
    textOp("printf", text, x, y, limit, align, r, sx, sy)
    return real.printf(text, x, y, limit, align, r, sx, sy, ...)
  end

  g.newImage = function(src, ...)
    local img = real.newImage(src, ...)
    if type(src) == "string" then rawset(img, "path", src)
    elseif type(src) == "table" and rawget(src, "path") then rawset(img, "path", rawget(src, "path")) end
    return img
  end
  local realNID = love.image.newImageData
  love.image.newImageData = function(a, ...)
    local d = realNID(a, ...)
    if type(a) == "string" then rawset(d, "path", a) end
    return d
  end

  g.draw = function(drawable, a, ...)
    local quad, x, y, r, sx, sy, ox, oy
    if type(a) == "table" and a.getViewport then
      quad = a
      x, y, r, sx, sy, ox, oy = ...
    else
      x, y, r, sx, sy, ox, oy = a, ...
    end
    x, y, r, sx, sy, ox, oy = x or 0, y or 0, r or 0, sx or 1, sy or sx or 1, ox or 0, oy or 0
    local qx, qy, qw, qh
    local tw, th = 0, 0
    if drawable and drawable.getDimensions then tw, th = drawable:getDimensions() end
    if quad then qx, qy, qw, qh = quad:getViewport() else qx, qy, qw, qh = 0, 0, tw, th end
    local x0, y0 = apply(x - ox * sx, y - oy * sy)
    local x1, y1 = apply(x + (qw - ox) * sx, y + (qh - oy) * sy)
    push({ op = "image", path = drawable and rawget(drawable, "path") or nil,
      canvas = drawable and rawget(drawable, "canvas") or nil,
      x0 = math.min(x0, x1), y0 = math.min(y0, y1), x1 = math.max(x0, x1), y1 = math.max(y0, y1),
      qx = qx, qy = qy, qw = qw, qh = qh, tw = tw, th = th })
    return real.draw(drawable, a, ...)
  end

  g.present = function(...)
    Rec.last = Rec.frame
    Rec.frame = {}
    return real.present(...)
  end
end

-- minimal JSON
local function enc(v)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    return string.format("%.3f", v)
  elseif t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c)
      return string.format("\\u%04x", c:byte())
    end) .. '"'
  elseif t == "boolean" then return tostring(v)
  elseif t == "table" then
    if #v > 0 or next(v) == nil then
      local parts = {}
      for i = 1, #v do parts[i] = enc(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do parts[#parts + 1] = enc(tostring(k)) .. ":" .. enc(val) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function Rec.dump(path, meta)
  local f = assert(io.open(path, "w"))
  f:write(enc({ meta = meta or {}, ops = Rec.last }))
  f:close()
end

return Rec
