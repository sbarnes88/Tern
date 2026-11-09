"""Headless renderer: draws a Tern render tree to a PNG (browser-style window).

Used for screenshots and for checking pages on machines with no display.
"""
import os
from PIL import Image, ImageDraw, ImageFont

BG, FG, MUTED = "#ffffff", "#1f2328", "#6e7781"
LINK, BTN, BTN_BORDER = "#0b57d0", "#eef1f6", "#c5cbd6"
PAD, GAP = 24, 10


def _font(size, bold=False):
    names = (["DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf"] if bold
             else ["DejaVuSans.ttf", "LiberationSans-Regular.ttf"])
    for n in names:
        for d in ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/truetype/liberation", ""):
            try:
                return ImageFont.truetype(os.path.join(d, n), size)
            except OSError:
                pass
    return ImageFont.load_default(size)


F_BODY, F_HEAD, F_BOLD, F_SMALL = _font(16), _font(30, True), _font(16, True), _font(13)


def _tw(d, s, f):
    return d.textlength(s, font=f)


def _wrap(d, s, f, maxw):
    lines = []
    for para in s.split("\n"):
        cur = ""
        for word in para.split(" "):
            trial = (cur + " " + word).strip()
            if cur and _tw(d, trial, f) > maxw:
                lines.append(cur)
                cur = word
            else:
                cur = trial
        lines.append(cur)
    return lines


def _block(nodes, d, x, y, maxw, horizontal=False, draw=True):
    """Lay out nodes; returns (width, height). Draws only when draw=True."""
    cx, cy, w, h = x, y, 0, 0
    for n in nodes:
        t = n["t"]
        if t in ("heading", "text"):
            f = F_HEAD if t == "heading" else F_BODY
            lines = _wrap(d, n["text"], f, maxw if not horizontal else maxw * 0.6)
            lh = f.size + 8
            nw = max((_tw(d, ln, f) for ln in lines), default=0)
            nh = lh * len(lines)
            if draw:
                for i, ln in enumerate(lines):
                    d.text((cx, cy + i * lh), ln, font=f, fill=FG)
        elif t == "button":
            nw, nh = _tw(d, n["label"], F_BODY) + 28, 34
            if draw:
                d.rounded_rectangle((cx, cy, cx + nw, cy + nh), 6, fill=BTN, outline=BTN_BORDER)
                d.text((cx + 14, cy + 7), n["label"], font=F_BODY, fill=FG)
        elif t == "input":
            nw, nh = 260, 34
            if draw:
                d.rounded_rectangle((cx, cy, cx + nw, cy + nh), 4, fill="#fff", outline="#8c959f")
                shown, col = (n["value"], FG) if n["value"] else (n["placeholder"], MUTED)
                d.text((cx + 10, cy + 7), shown, font=F_BODY, fill=col)
        elif t == "link":
            nw, nh = _tw(d, n["text"], F_BODY), 24
            if draw:
                d.text((cx, cy), n["text"], font=F_BODY, fill=LINK)
                d.line((cx, cy + 20, cx + nw, cy + 20), fill=LINK)
        elif t == "divider":
            nw, nh = maxw, 12
            if draw:
                d.line((cx, cy + 6, cx + maxw, cy + 6), fill=BTN_BORDER, width=1)
        elif t in ("row", "column"):
            nw, nh = _block(n["children"], d, cx, cy, maxw, t == "row", draw)
        else:
            nw = nh = 0
        if horizontal:
            cx, w, h = cx + nw + GAP, w + nw + GAP, max(h, nh)
        else:
            cy, w, h = cy + nh + GAP, max(w, nw), h + nh + GAP
    return w, h


def render_png(nodes, path, title="Untitled", address="", width=720, error_lines=None):
    scratch = ImageDraw.Draw(Image.new("RGB", (10, 10)))
    maxw = width - 2 * PAD
    _, body_h = _block(nodes, scratch, 0, 0, maxw, draw=False)
    extra = 0
    if error_lines:
        error_lines = [w for ln in error_lines for w in _wrap(scratch, ln, F_BODY, maxw)]
        extra = 28 * len(error_lines) + 24
    tool_h = 92
    height = max(tool_h + PAD * 2 + body_h + extra, 260)
    img = Image.new("RGB", (width, height), BG)
    d = ImageDraw.Draw(img)

    # window chrome: tab + toolbar
    d.rectangle((0, 0, width, 38), fill="#dfe3ea")
    d.rounded_rectangle((12, 8, 240, 38), 8, fill="#f6f8fa")
    d.text((26, 14), title[:22], font=F_SMALL, fill=FG)
    d.rectangle((0, 38, width, tool_h), fill="#f6f8fa")
    for i, g in enumerate(["<", ">", "R"]):
        d.text((16 + i * 34, 52), g, font=F_BOLD, fill=MUTED)
    d.rounded_rectangle((120, 46, width - 16, 82), 16, fill="#ffffff", outline=BTN_BORDER)
    d.text((140, 55), address, font=F_BODY, fill=MUTED)
    d.line((0, tool_h, width, tool_h), fill=BTN_BORDER)

    y = tool_h + PAD
    if error_lines:
        for ln in error_lines:
            d.text((PAD, y), ln, font=F_BODY, fill="#b3261e")
            y += 28
        y += 24
    _block(nodes, d, PAD, y, maxw)
    img.save(path)
    return path
