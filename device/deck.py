#!/usr/bin/env python3
"""
deck.py — drive the Stream Dock 293 (0x5548:0x6674) without the vendor app.

Two halves, because the vendor Python SDK only gets one of them right on this unit:

  images  -> the vendor SDK (MIT) with a one-line PID registration. Verified: 85/96/100 px
             faces render, 18 slots addressable.
  input   -> NOT the SDK. Its decoder requires "ACK"/"OK" framing the firmware never sends,
             so presses vanish. A 120-line Swift IOHID reader (hidreader) streams JSON lines
             instead.

Usage:
    ./deck.py key 1 photo.png            # draw a file on a key (logical 1..18)
    ./deck.py text 3 "Streaming"         # draw a generated face with text
    ./deck.py clear                      # blank every key
    ./deck.py listen                     # stream key presses as JSON lines
    ./deck.py info                       # device + firmware + mapping

Requires: ./.venv (pillow), ./hidreader (built by ./build.sh), sdk/ (vendored).
"""
import argparse
import json
import os
import subprocess
import sys

# Re-exec under the project venv: the vendored SDK uses PEP 604 annotations and needs 3.10+,
# while /usr/bin/python3 on this Mac is 3.9. Keeps ./deck.py runnable as-is.
_VENV_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".venv", "bin", "python")
if os.path.exists(_VENV_PY) and os.path.realpath(sys.executable) != os.path.realpath(_VENV_PY):
    os.execv(_VENV_PY, [_VENV_PY, os.path.abspath(__file__)] + sys.argv[1:])

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "sdk", "src"))

from PIL import Image, ImageDraw, ImageFont                       # noqa: E402
from StreamDock import ProductIDs as PID_TABLE                   # noqa: E402
from StreamDock.Devices.StreamDock293s import StreamDock293s     # noqa: E402

VID, PID = 0x5548, 0x6674
PID_TABLE.g_products.append((VID, PID, StreamDock293s))           # the whole port

from StreamDock.DeviceManager import DeviceManager               # noqa: E402

HW_TO_LOGICAL = {v: k for k, v in StreamDock293s._IMAGE_KEY_MAP.items()}


def open_device():
    devs = DeviceManager().enumerate()
    if not devs:
        sys.exit(f"no device at {VID:#06x}:{PID:#06x}")
    dev = devs[0]
    if not dev.open():
        sys.exit("open failed")
    dev.set_device()        # report sizes 513/513; without it the SDK's reader aborts (SIGABRT)
    dev.init()              # wake + brightness + clear + refresh; without it writes are invisible
    return dev


def face(text, size=85, bg=(28, 40, 56), fg=(240, 240, 240)):
    img = Image.new("RGB", (size, size), bg)
    d = ImageDraw.Draw(img)
    try:
        f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", max(12, int(size * 0.34)))
    except Exception:
        f = ImageFont.load_default()
    w = d.textlength(text, font=f)
    d.text(((size - w) / 2, size * 0.3), text, font=f, fill=fg)
    d.rectangle([0, 0, size - 1, size - 1], outline=(61, 154, 209))
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_key = sub.add_parser("key")
    p_key.add_argument("index", type=int, help="logical key 1..18")
    p_key.add_argument("image")

    p_text = sub.add_parser("text")
    p_text.add_argument("index", type=int)
    p_text.add_argument("label")

    sub.add_parser("clear")
    sub.add_parser("info")
    sub.add_parser("listen")
    sub.add_parser("selfcheck")
    sub.add_parser("demo")
    p_emo = sub.add_parser("emoji")
    p_emo.add_argument("glyphs", nargs="?", default=None,
                       help="18 emoji separated by spaces (default: built-in set)")
    p_id = sub.add_parser("identify")
    p_id.add_argument("--delay", type=float, default=0.8, help="seconds each slot stays lit")

    args = ap.parse_args()

    if args.cmd == "emoji":
        EMOJI_FONT = "/System/Library/Fonts/Apple Color Emoji.ttc"

        def emoji_tile(ch, size=85, ring=(61, 154, 209)):
            """Compose one slot: colour emoji centred on a dark tile with an accent ring."""
            img = Image.new("RGB", (size, size), (26, 30, 36))
            d = ImageDraw.Draw(img)
            for i in range(size):                      # soft vertical wash
                d.line([(0, i), (size, i)],
                       fill=(26 + i // 8, 30 + i // 7, 36 + i // 6))
            ef = ImageFont.truetype(EMOJI_FONT, 160)   # Apple Color Emoji only has a 160 px strike
            tmp = Image.new("RGBA", (160, 160), (0, 0, 0, 0))
            ImageDraw.Draw(tmp).text((0, 0), ch, font=ef, embedded_color=True)
            bbox = tmp.getbbox()
            if bbox:
                art = tmp.crop(bbox).resize((int(size * 0.72), int(size * 0.72)), Image.LANCZOS)
                img.paste(art, ((size - art.width) // 2, (size - art.height) // 2), art)
            d.rectangle([0, 0, size - 1, size - 1], outline=ring, width=1)
            return img

        default = ["😀", "😎", "🤖", "🎵", "🔥", "⭐", "❤️", "👍", "🎉", "🚀",
                   "🌈", "🍕", "☕", "📷", "🎮", "🕐", "🔋", "📶"]
        glyphs = args.glyphs.split() if args.glyphs else default
        if len(glyphs) != 18:
            print(f"need 18 emoji, got {len(glyphs)} — padding with the default set")
            glyphs = (glyphs + default)[:18]

        dev = open_device()
        try:
            dev.clearAllIcon()
            for k, ch in enumerate(glyphs, start=1):
                size = 80 if k >= 16 else 85
                path = f"/tmp/deck_emoji_{k}.jpg"
                emoji_tile(ch, size=size).save(path, "JPEG", quality=95)
                rc = dev.set_key_image(k, path)
                print(f"slot {k:2d} <- {ch}  (rc {rc})", flush=True)
            dev.refresh()
            print("emoji written to all 18 slots")
        finally:
            dev.close()
        return 0

    if args.cmd == "demo":
        import colorsys
        import time
        dev = open_device()
        try:
            dev.clearAllIcon()
            for k in range(1, 16):                     # 15 keypad keys
                h = (k - 1) / 15.0
                r, g, b = colorsys.hsv_to_rgb(h, 0.55, 0.42)
                bg = (int(r * 255), int(g * 255), int(b * 255))
                img = Image.new("RGB", (85, 85), bg)
                d = ImageDraw.Draw(img)
                # corner-to-corner gradient so the panel's colour range is visible too
                for i in range(85):
                    d.line([(0, i), (85, i)],
                           fill=(min(255, bg[0] + i // 3), min(255, bg[1] + i // 4), min(255, bg[2] + i // 2)))
                f_big = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 34)
                f_sml = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 11)
                t = str(k)
                w = d.textlength(t, font=f_big)
                d.text(((85 - w) / 2, 18), t, font=f_big, fill=(255, 255, 255))
                sub = f"KEY {k}"
                w2 = d.textlength(sub, font=f_sml)
                d.text(((85 - w2) / 2, 62), sub, font=f_sml, fill=(235, 235, 235))
                d.rectangle([0, 0, 84, 84], outline=(255, 255, 255), width=1)
                path = f"/tmp/deck_demo_k{k}.jpg"
                img.save(path, "JPEG", quality=94)
                dev.set_key_image(k, path)

            for n, k in enumerate(range(16, 19), start=1):   # the 1x3 window
                bg = [(120, 40, 40), (40, 110, 60), (40, 70, 130)][n - 1]
                img = Image.new("RGB", (80, 80), bg)
                d = ImageDraw.Draw(img)
                for i in range(80):
                    d.line([(i, 0), (i, 80)], fill=(bg[0] + i // 4, bg[1] + i // 4, bg[2] + i // 4))
                f_big = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 30)
                f_sml = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 10)
                t = str(n)
                w = d.textlength(t, font=f_big)
                d.text(((80 - w) / 2, 14), t, font=f_big, fill=(255, 255, 255))
                sub = f"WIN {n}/3"
                w2 = d.textlength(sub, font=f_sml)
                d.text(((80 - w2) / 2, 58), sub, font=f_sml, fill=(240, 240, 240))
                d.rectangle([0, 0, 79, 79], outline=(255, 255, 255), width=1)
                path = f"/tmp/deck_demo_w{n}.jpg"
                img.save(path, "JPEG", quality=94)
                dev.set_key_image(k, path)

            dev.refresh()
            time.sleep(0.4)
            print("demo drawn on all 18 slots: 15 keypad keys (1-15) + 3 window panes (WIN 1/3..3/3)")
        finally:
            dev.close()
        return 0

    if args.cmd == "identify":
        import time
        dev = open_device()
        try:
            dev.clearAllIcon()
            for k in range(1, 19):
                path = f"/tmp/deck_id_{k}.jpg"
                face(str(k), size=85, bg=(20, 60, 90)).save(path, "JPEG", quality=92)
                dev.set_key_image(k, path)
                print(f"slot {k:2d} lit", flush=True)
                time.sleep(args.delay)
                # leave it lit; the next one joins it, so the end state is 1..18 shown
            dev.refresh()
            print("all 18 slots lit — button 1..15 are the keypad, 16..18 the window")
        finally:
            dev.close()
        return 0

    if args.cmd == "selfcheck":
        ok = True
        # 1. IOHID view: identity, report geometry, firmware feature report
        probe = subprocess.run([os.path.join(HERE, "hidprobe"), "1"],
                               capture_output=True, text=True)
        out = probe.stdout
        for needle, label in [("VendorID", "vid"), ("ProductID", "pid"),
                              ("V2.", "firmware"), ("input reports", "input")]:
            line = next((l.strip() for l in out.splitlines() if needle in l), None)
            print(f"  {'OK ' if line else 'FAIL'} {label:9s} {line or ''}")
            ok &= bool(line)
        # 2. SDK view: can it open the device and report firmware
        try:
            dev = open_device()
            print(f"  OK  sdk       {type(dev).__name__} fw={getattr(dev, 'firmware_version', None)}"
                  f" keys={StreamDock293s.KEY_COUNT}")
            dev.close()
        except SystemExit as e:
            print(f"  FAIL sdk       {e}")
            ok = False
        # 3. input helper present and launches
        helper = os.path.join(HERE, "hidreader")
        if os.path.exists(helper):
            r = subprocess.run([helper, "1"], capture_output=True, text=True)
            ready = '"ready":true' in r.stdout.replace(" ", "")
            print(f"  {'OK ' if ready else 'FAIL'} reader    "
                  f"{'armed' if ready else r.stdout.strip()[:80]}")
            ok &= ready
        else:
            print("  FAIL reader    hidreader missing (run ./build.sh)")
            ok = False
        print("\nselfcheck:", "PASS" if ok else "FAIL")
        return 0 if ok else 1

    if args.cmd == "listen":
        # input comes from the Swift reader: the SDK cannot decode this firmware's packets
        helper = os.path.join(HERE, "hidreader")
        if not os.path.exists(helper):
            sys.exit("hidreader missing — run ./build.sh")
        proc = subprocess.Popen([helper], stdout=subprocess.PIPE, text=True)
        try:
            for line in proc.stdout:
                line = line.strip()
                if line:
                    print(line, flush=True)
        except KeyboardInterrupt:
            pass
        finally:
            proc.terminate()
        return 0

    dev = open_device()
    try:
        if args.cmd == "info":
            print(json.dumps({
                "device": type(dev).__name__,
                "path": dev.path,
                "firmware": getattr(dev, "firmware_version", None),
                "keys": StreamDock293s.KEY_COUNT,
                "layout": {
                    "buttons": "5 columns x 3 rows = 15 pressable keys (logical 1-15)",
                    "window": "1 x 3 display window, 3 slots, display-only (logical 16-18)",
                    "mapping": "logical 1-5 = top row left->right, 6-10 = middle, 11-15 = bottom",
                },
                "mapping": {str(k): v for k, v in sorted(HW_TO_LOGICAL.items())},
            }, indent=1))
        elif args.cmd == "clear":
            dev.clearAllIcon()
            dev.refresh()
            print("cleared")
        elif args.cmd == "key":
            rc = dev.set_key_image(args.index, args.image)
            print(f"key {args.index} <- {args.image} (rc {rc})")
        elif args.cmd == "text":
            path = f"/tmp/deck_face_{args.index}.jpg"
            face(args.label).save(path, "JPEG", quality=92)
            rc = dev.set_key_image(args.index, path)
            print(f"key {args.index} <- {args.label!r} (rc {rc})")
    finally:
        dev.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
