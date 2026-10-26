#!/usr/bin/env python3
"""Generate Deckhand's built-in key graphics.

Everything here is drawn from scratch (rounded key face + a Unicode glyph), so the resulting
PNGs are original to this project and carry no third-party asset licence. Re-run to restyle:

    python3 tools/make_library.py app/Resources/Library
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFont

SIDE = 170              # 2× the 85 px the panel wants, so it stays crisp when scaled
BG = (42, 47, 58)       # key face
GLYPH = (238, 241, 245)
ACCENT = (34, 211, 238)

FONT_PATHS = [
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]

ICONS = [
    # media
    ("play", "▶", GLYPH), ("pause", "❚❚", GLYPH), ("stop", "■", GLYPH),
    ("previous", "⏮", GLYPH), ("next", "⏭", GLYPH),
    ("music", "♫", GLYPH),
    # productivity
    ("home", "⌂", GLYPH), ("search", "⌕", GLYPH), ("settings", "⚙", GLYPH),
    ("mail", "✉", GLYPH), ("calendar", "▦", GLYPH), ("clock", "◷", GLYPH),
    ("terminal", ">_", ACCENT), ("code", "</>", ACCENT),
    ("folder", "▤", GLYPH), ("save", "⤓", GLYPH), ("print", "⎙", GLYPH),
    ("trash", "⌫", GLYPH), ("refresh", "⟳", GLYPH),
    # system
    ("power", "⏻", GLYPH), ("cpu", "▣", ACCENT),
    # web / capture

    ("record", "●", (244, 114, 182)),
    # misc
    ("star", "★", (250, 204, 21)), ("heart", "♥", (244, 63, 94)),
    ("check", "✓", (74, 222, 128)), ("cross", "✗", (248, 113, 113)),
    ("plus", "＋", GLYPH), ("minus", "－", GLYPH),
    ("up", "▲", GLYPH), ("down", "▼", GLYPH), ("left", "◀", GLYPH), ("right", "▶", GLYPH),
    ("command", "⌘", GLYPH), ("shift", "⇧", GLYPH), ("escape", "⎋", GLYPH),
    ("return", "⏎", GLYPH), ("delete", "⌦", GLYPH), ("eject", "⏏", GLYPH),
    ("bolt", "⚡", (250, 204, 21)),
    ("sun", "☀", (250, 204, 21)), ("moon", "☾", GLYPH),
    ("coffee", "☕", GLYPH),
]

# digits and letters make good page/profile keys
ICONS += [(str(n), str(n), GLYPH) for n in range(1, 10)]
ICONS += [(chr(c), chr(c), GLYPH) for c in range(ord("A"), ord("H") + 1)]


VECTOR = ["volume", "volume-up", "volume-down", "mute", "lock", "unlock", "bell", "battery",
          "wifi", "bluetooth", "globe", "camera", "mic", "chat", "speaker", "video", "shield",
          "download", "upload"]


def draw_vector(d: ImageDraw.ImageDraw, name: str, c):
    cx, cy = SIDE / 2, SIDE / 2
    w = 5                                     # stroke width
    if name in ("volume", "volume-up", "volume-down", "mute", "speaker"):
        d.polygon([(cx - 46, cy - 18), (cx - 22, cy - 18), (cx + 4, cy - 44),
                   (cx + 4, cy + 44), (cx - 22, cy + 18), (cx - 46, cy + 18)], fill=c)
        if name == "mute":
            d.line([(cx + 14, cy - 22), (cx + 52, cy + 22)], fill=c, width=w + 1)
            d.line([(cx + 52, cy - 22), (cx + 14, cy + 22)], fill=c, width=w + 1)
        else:
            radii = {"volume": (24, 42), "volume-up": (22, 40, 58),
                     "volume-down": (26,), "speaker": (36,)}[name]
            for r in radii:
                d.arc([cx + 4 - r, cy - r, cx + 4 + r, cy + r], start=-58, end=58, fill=c, width=w)
    elif name in ("lock", "unlock"):
        d.rounded_rectangle([cx - 34, cy - 6, cx + 34, cy + 46], radius=10, fill=c)
        if name == "lock":
            d.arc([cx - 24, cy - 46, cx + 24, cy + 10], start=180, end=360, fill=c, width=w + 2)
        else:
            d.arc([cx - 24, cy - 52, cx + 24, cy + 4], start=180, end=300, fill=c, width=w + 2)
    elif name == "bell":
        d.pieslice([cx - 38, cy - 52, cx + 38, cy + 24], start=180, end=360, fill=c)
        d.rectangle([cx - 38, cy - 14, cx + 38, cy + 26], fill=c)
        d.ellipse([cx - 10, cy + 28, cx + 10, cy + 46], fill=c)
    elif name == "battery":
        d.rounded_rectangle([cx - 46, cy - 24, cx + 34, cy + 24], radius=8, outline=c, width=w)
        d.rounded_rectangle([cx + 36, cy - 10, cx + 48, cy + 10], radius=3, fill=c)
        d.rectangle([cx - 38, cy - 16, cx + 2, cy + 16], fill=c)
    elif name == "wifi":
        d.ellipse([cx - 8, cy + 22, cx + 8, cy + 38], fill=c)
        for r in (26, 50, 74):
            d.arc([cx - r, cy + 30 - r, cx + r, cy + 30 + r], start=215, end=325, fill=c, width=w)
    elif name == "bluetooth":
        d.line([(cx, cy - 46), (cx, cy + 46)], fill=c, width=w)
        d.line([(cx, cy - 46), (cx + 30, cy - 22), (cx - 30, cy + 22), (cx, cy + 46)], fill=c, width=w)
        d.line([(cx, cy), (cx + 30, cy + 22), (cx - 30, cy - 22)], fill=c, width=w)
    elif name == "globe":
        d.ellipse([cx - 44, cy - 44, cx + 44, cy + 44], outline=c, width=w)
        d.ellipse([cx - 18, cy - 44, cx + 18, cy + 44], outline=c, width=w)
        d.line([(cx - 44, cy), (cx + 44, cy)], fill=c, width=w)
    elif name in ("camera", "video"):
        d.rounded_rectangle([cx - 46, cy - 26, cx + 46, cy + 34], radius=10, fill=c)
        d.ellipse([cx - 18, cy - 8, cx + 18, cy + 28], fill=BG)
        if name == "video":
            d.polygon([(cx + 10, cy + 18), (cx + 30, cy + 30), (cx + 30, cy + 6)], fill=BG)
    elif name == "mic":
        d.rounded_rectangle([cx - 16, cy - 48, cx + 16, cy + 14], radius=16, fill=c)
        d.arc([cx - 32, cy - 18, cx + 32, cy + 34], start=0, end=180, fill=c, width=w)
        d.line([(cx, cy + 34), (cx, cy + 50)], fill=c, width=w)
    elif name == "chat":
        d.rounded_rectangle([cx - 46, cy - 40, cx + 46, cy + 22], radius=14, fill=c)
        d.polygon([(cx - 14, cy + 20), (cx + 8, cy + 20), (cx - 14, cy + 46)], fill=c)
    elif name in ("shield", "download", "upload"):
        if name == "shield":
            d.polygon([(cx, cy - 46), (cx + 42, cy - 26), (cx + 42, cy + 12),
                       (cx, cy + 48), (cx - 42, cy + 12), (cx - 42, cy - 26)], outline=c, width=w)
        else:
            down = name == "download"
            d.line([(cx, cy - 40 if down else cy + 40), (cx, cy + 30 if down else cy - 30)], fill=c, width=w)
            tip = 30 if down else -30
            d.line([(cx - 20, tip - 18 if down else tip + 18), (cx, tip),
                    (cx + 20, tip - 18 if down else tip + 18)], fill=c, width=w)
            d.line([(cx - 34, cy + 46), (cx + 34, cy + 46)], fill=c, width=w)


def font_for(text: str, size: int):
    for path in FONT_PATHS:
        if not os.path.exists(path):
            continue
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()


def render(glyph, colour, path, vector=None):
    img = Image.new("RGB", (SIDE, SIDE), BG)
    d = ImageDraw.Draw(img)

    # key face: subtle inner border so tiles read as keys even on a dark panel
    d.rounded_rectangle([3, 3, SIDE - 4, SIDE - 4], radius=26, outline=(255, 255, 255, 26), width=2)

    if vector:
        draw_vector(d, vector, colour)
        img.save(path, "PNG")
        return

    size = 96 if len(glyph) > 2 else (110 if len(glyph) > 1 else 104)
    font = font_for(glyph, size)
    box = d.textbbox((0, 0), glyph, font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    if w > SIDE - 28:                       # shrink long glyphs like "</>" or ">_"
        size = int(size * (SIDE - 28) / w)
        font = font_for(glyph, size)
        box = d.textbbox((0, 0), glyph, font=font)
        w, h = box[2] - box[0], box[3] - box[1]
    d.text(((SIDE - w) / 2 - box[0], (SIDE - h) / 2 - box[1]), glyph, fill=colour, font=font)
    img.save(path, "PNG")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "app/Resources/Library"
    os.makedirs(out, exist_ok=True)
    for name, glyph, colour in ICONS:
        render(glyph, colour, os.path.join(out, f"{name}.png"))
    for name in VECTOR:
        render("", GLYPH, os.path.join(out, f"{name}.png"), vector=name)
    print(f"{len(ICONS) + len(VECTOR)} icons written to {out}")


if __name__ == "__main__":
    main()
