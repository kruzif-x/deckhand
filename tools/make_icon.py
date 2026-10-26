#!/usr/bin/env python3
"""Generate Deckhand's app icon.

Drawn from scratch so the asset is original and reproducible:

    python3 tools/make_icon.py app/Resources/AppIcon.icns [accent]

The motif is the hardware itself: a 5x3 keypad with one lit key, beside the continuous 1x3 display
strip that lives to the right of keys 5 / 10 / 15. macOS icon grid: 824 of 1024 for the body.
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096                    # supersample, then downscale to 1024
CONTENT = 3296              # 824/1024 of the canvas
RADIUS = 740
OFF = (S - CONTENT) // 2

ACCENTS = {
    "cyan": (34, 211, 238),
    "mint": (52, 211, 153),
    "indigo": (129, 140, 248),
}


def gradient(size, top, bottom):
    g = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / (size - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return g.resize((size, size))


def squircle_mask(size, content, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([OFF, OFF, OFF + content, OFF + content],
                                        radius=radius, fill=255)
    return m


def build(accent):
    mask = squircle_mask(S, CONTENT, RADIUS)
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # body: vertical gradient plus a soft top-left light, the way macOS icons are lit
    img.paste(gradient(S, (44, 49, 62), (17, 19, 24)), (0, 0))
    light = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(light).ellipse([OFF - 400, OFF - 900, OFF + 2400, OFF + 1500],
                                  fill=(255, 255, 255, 26))
    img.alpha_composite(light.filter(ImageFilter.GaussianBlur(120)))

    k, gap = 430, 96
    grid_w, grid_h = 5 * k + 4 * gap, 3 * k + 2 * gap
    strip_w = 430
    left = OFF + (CONTENT - grid_w - 150 - strip_w) // 2
    top = OFF + (CONTENT - grid_h) // 2
    lit = (2, 1)                                    # centre key of the grid

    # keys cast shadows onto the body
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    for r in range(3):
        for c in range(5):
            x, y = left + c * (k + gap), top + r * (k + gap)
            sd.rounded_rectangle([x + 12, y + 30, x + k + 12, y + k + 30], radius=76, fill=(0, 0, 0, 150))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(34)))

    d = ImageDraw.Draw(img, "RGBA")
    for r in range(3):
        for c in range(5):
            if (c, r) == lit:
                continue
            x, y = left + c * (k + gap), top + r * (k + gap)
            d.rounded_rectangle([x, y, x + k, y + k], radius=84, fill=(88, 99, 120, 255))
            d.rounded_rectangle([x, y + 18, x + k, y + k], radius=84, fill=(70, 80, 98, 255))
            d.rounded_rectangle([x + 8, y + 8, x + k - 8, y + k - 30], radius=76,
                                outline=(255, 255, 255, 52), width=8)

    # the lit key: tight glow plus a bright face
    cx = left + lit[0] * (k + gap) + k // 2
    cy = top + lit[1] * (k + gap) + k // 2
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).rounded_rectangle([cx - k // 2 - 44, cy - k // 2 - 44,
                                            cx + k // 2 + 44, cy + k // 2 + 44],
                                           radius=100, fill=accent + (115,))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(58)))
    d = ImageDraw.Draw(img, "RGBA")
    d.rounded_rectangle([cx - k // 2, cy - k // 2, cx + k // 2, cy + k // 2],
                        radius=76, fill=accent + (255,))
    d.rounded_rectangle([cx - k // 2 + 9, cy - k // 2 + 9, cx + k // 2 - 9, cy + k // 2 - 9],
                        radius=68, outline=(255, 255, 255, 105), width=8)

    # the 1x3 window: one recessed screen, not three tiles
    sx = left + grid_w + 150
    d.rounded_rectangle([sx, top, sx + strip_w, top + grid_h], radius=116, fill=(9, 11, 15, 255))
    d.rounded_rectangle([sx + 7, top + 7, sx + strip_w - 7, top + grid_h - 7], radius=110,
                        outline=(255, 255, 255, 24), width=6)
    inset = [sx + 34, top + 34, sx + strip_w - 34, top + grid_h - 34]
    d.rounded_rectangle(inset, radius=88, fill=(15, 22, 28, 255))

    screen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(screen).rounded_rectangle(inset, radius=88, fill=accent + (40,))
    img.alpha_composite(screen.filter(ImageFilter.GaussianBlur(26)))
    d = ImageDraw.Draw(img, "RGBA")

    w0 = inset[2] - inset[0]
    # one bold screen block reads as a display even at 64 px; a hairline under it suggests UI
    d.rounded_rectangle([inset[0] + 52, inset[1] + 92, inset[0] + 52 + int(w0 * 0.62),
                         inset[1] + 372], radius=64, fill=accent + (250,))
    d.rounded_rectangle([inset[0] + 52, inset[1] + 424, inset[0] + 52 + int(w0 * 0.86),
                         inset[1] + 468], radius=24, fill=(255, 255, 255, 90))

    img.putalpha(mask)

    # outer shadow, then a hairline rim: what makes it sit like a macOS icon
    drop = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(drop).rounded_rectangle([OFF + 6, OFF + 26, OFF + CONTENT - 6, OFF + CONTENT + 26],
                                           radius=RADIUS, fill=(0, 0, 0, 110))
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    canvas.alpha_composite(drop.filter(ImageFilter.GaussianBlur(46)))
    canvas.alpha_composite(img)

    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle([OFF + 2, OFF + 2, OFF + CONTENT - 2, OFF + CONTENT - 2],
                                          radius=RADIUS, outline=(255, 255, 255, 30), width=6)
    canvas.alpha_composite(rim)

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "app/Resources/AppIcon.icns"
    accent_name = sys.argv[2] if len(sys.argv) > 2 else "cyan"
    accent = ACCENTS.get(accent_name, ACCENTS["cyan"])

    base = os.path.dirname(os.path.abspath(out))
    preview = os.path.join(base, "AppIcon-1024.png")
    os.makedirs(base, exist_ok=True)
    icon = build(accent)
    icon.save(preview)

    iconset = "/tmp/Deckhand.iconset"
    os.system(f"rm -rf {iconset}")
    os.makedirs(iconset, exist_ok=True)
    for s in (16, 32, 128, 256, 512):
        icon.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
        icon.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
    os.system(f"iconutil -c icns {iconset} -o '{out}'")
    print(f"wrote {out} ({accent_name}) and {preview}")


if __name__ == "__main__":
    main()
