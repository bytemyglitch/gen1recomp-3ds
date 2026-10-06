#!/usr/bin/env python3
"""Render a frame recorded by drawrec.lua to PNG.

    render_shot.py FRAME.json GAME_DIR OUT.png [--scale 3] [--overview OUT2.png]

The main image is the 3DS top screen (400x240) at --scale; --bottom also
renders the bottom screen (320x240).  --overview also
writes a 1x picture of a larger area with the screen outlined in red, to show
what the launcher draws off-screen.
"""
import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont

FONT_PATH = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
_font_cache = {}
_image_cache = {}


def font(px):
    px = max(4, int(round(px)))
    if px not in _font_cache:
        _font_cache[px] = ImageFont.truetype(FONT_PATH, px)
    return _font_cache[px]


def rgba(c, alpha_mul=1.0):
    r, g, b, a = (c + [1, 1, 1, 1])[:4]
    clamp = lambda v: max(0, min(255, int(round(v * 255))))
    return (clamp(r), clamp(g), clamp(b), clamp(a * alpha_mul))


def load_image(game_dir, path):
    if path not in _image_cache:
        full = os.path.join(game_dir, path)
        _image_cache[path] = Image.open(full).convert("RGBA") if os.path.exists(full) else None
    return _image_cache[path]


def wrap(text, size, limit):
    adv = max(1.0, size * 0.6)
    per = max(1, int(limit // adv)) if limit else 10 ** 6
    lines = []
    for raw in text.split("\n"):
        if raw == "":
            lines.append("")
            continue
        words, cur = raw.split(" "), ""
        for w in words:
            cand = (cur + " " + w) if cur else w
            if len(cand) <= per:
                cur = cand
            else:
                if cur:
                    lines.append(cur)
                while len(w) > per:
                    lines.append(w[:per])
                    w = w[per:]
                cur = w
        lines.append(cur)
    return lines


def render(frame, game_dir, ox, oy, w, h, scale, screen="top"):
    base = Image.new("RGBA", (int(w * scale), int(h * scale)), (0, 0, 0, 255))
    for op in frame["ops"]:
        if op.get("screen", "top") != screen:
            continue
        layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        T = lambda x, y: ((x - ox) * scale, (y - oy) * scale)
        col = rgba(op.get("color", [1, 1, 1, 1]))
        kind = op["op"]
        lw = max(1, int(round(op.get("lw", 1) * scale)))
        if kind == "rect":
            x0, y0 = T(op["x0"], op["y0"])
            x1, y1 = T(op["x1"], op["y1"])
            if x1 - x0 >= 0.5 and y1 - y0 >= 0.5:
                r = min(op.get("r", 0) * scale, (x1 - x0) / 2, (y1 - y0) / 2)
                if op["mode"] == "fill":
                    d.rounded_rectangle([x0, y0, x1 - 1, y1 - 1], radius=r, fill=col)
                else:
                    d.rounded_rectangle([x0, y0, x1 - 1, y1 - 1], radius=r, outline=col, width=lw)
        elif kind in ("poly", "line"):
            pts = op["pts"]
            xy = [T(pts[i], pts[i + 1]) for i in range(0, len(pts) - 1, 2)]
            if len(xy) >= 2:
                if kind == "poly" and op.get("mode") == "fill" and len(xy) >= 3:
                    d.polygon(xy, fill=col)
                elif kind == "poly":
                    d.line(xy + [xy[0]], fill=col, width=lw)
                else:
                    d.line(xy, fill=col, width=lw)
        elif kind == "circle":
            cx, cy = T(op["x"], op["y"])
            r = op["r"] * scale
            if op["mode"] == "fill":
                d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=col)
            else:
                d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=col, width=lw)
        elif kind == "text":
            size = op["size"] * scale
            f = font(size)
            x, y = T(op["x"], op["y"])
            limit = op.get("limit")
            lines = wrap(op["text"], op["size"], limit) if limit else op["text"].split("\n")
            for i, line in enumerate(lines):
                lx = x
                if limit:
                    tw = len(line) * op["size"] * 0.6 * scale
                    if op.get("align") == "center":
                        lx = x + (limit * scale - tw) / 2
                    elif op.get("align") == "right":
                        lx = x + (limit * scale - tw)
                d.text((lx, y + i * size * 1.2), line, font=f, fill=col)
        elif kind == "image":
            x0, y0 = T(op["x0"], op["y0"])
            x1, y1 = T(op["x1"], op["y1"])
            if x1 - x0 < 1 or y1 - y0 < 1:
                continue
            src = load_image(game_dir, op["path"]) if op.get("path") else None
            if src is not None:
                qx, qy, qw, qh = op["qx"], op["qy"], op["qw"], op["qh"]
                piece = src.crop((int(qx), int(qy), int(qx + qw), int(qy + qh)))
                piece = piece.resize((max(1, int(x1 - x0)), max(1, int(y1 - y0))), Image.NEAREST)
                tint = Image.new("RGBA", piece.size, col)
                piece = Image.composite(
                    Image.blend(piece, Image.new("RGBA", piece.size, (0, 0, 0, 0)), 0),
                    piece, piece)
                r, g, b, a = piece.split()
                tr, tg, tb, ta = col
                piece = Image.merge("RGBA", (
                    r.point(lambda v: v * tr // 255), g.point(lambda v: v * tg // 255),
                    b.point(lambda v: v * tb // 255), a.point(lambda v: v * ta // 255)))
                layer.alpha_composite(piece, (int(x0), int(y0)))
            else:
                # generated art or a canvas: a neutral placeholder box
                d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=(90, 90, 110, 160),
                            outline=(160, 160, 190, 255))
        sc = op.get("scissor")
        if sc:
            mask = Image.new("L", base.size, 0)
            sx0, sy0 = T(sc[0], sc[1])
            sx1, sy1 = T(sc[0] + sc[2], sc[1] + sc[3])
            ImageDraw.Draw(mask).rectangle([sx0, sy0, sx1 - 1, sy1 - 1], fill=255)
            layer.putalpha(Image.composite(layer.split()[3], Image.new("L", base.size, 0), mask))
        base.alpha_composite(layer)
    return base


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frame")
    ap.add_argument("game_dir")
    ap.add_argument("out")
    ap.add_argument("--scale", type=float, default=3)
    ap.add_argument("--overview")
    ap.add_argument("--bottom", help="also render the bottom screen (320x240) here")
    a = ap.parse_args()
    frame = json.load(open(a.frame))
    render(frame, a.game_dir, 0, 0, 400, 240, a.scale).convert("RGB").save(a.out)
    if a.bottom:
        render(frame, a.game_dir, 0, 0, 320, 240, a.scale, "bottom").convert("RGB").save(a.bottom)
    if a.overview:
        tops = [op for op in frame["ops"] if op.get("screen", "top") == "top"]
        xs = [v for op in tops for k, v in op.items() if k in ("x0", "x1", "x") and isinstance(v, (int, float))]
        ys = [v for op in tops for k, v in op.items() if k in ("y0", "y1", "y") and isinstance(v, (int, float))]
        x0, y0 = min([0] + xs) - 10, min([0] + ys) - 10
        x1, y1 = min(max([400] + xs) + 10, 2000), min(max([240] + ys) + 10, 2000)
        ov = render(frame, a.game_dir, x0, y0, x1 - x0, y1 - y0, 1)
        ImageDraw.Draw(ov).rectangle([-x0, -y0, -x0 + 400, -y0 + 240], outline=(255, 0, 0, 255), width=2)
        ov.convert("RGB").save(a.overview)


if __name__ == "__main__":
    main()
