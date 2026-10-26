#!/usr/bin/env python3
"""
drive_test.py — prove the device can actually be driven, with no vendor app.

Uses the vendor's own open-source Python SDK (MIT, github.com/MiraboxSpace/
StreamDock-Device-SDK) but teaches it this unit's PID: the SDK table maps
0x5548:0x6670 to StreamDock293s, while this unit enumerates as 0x5548:0x6674
(see ../device/README.md). One line of registration is the whole patch.

    ./.venv/bin/python drive_test.py --keys 1,5 --listen 20

Writes JPEG key faces (85x85, rotated 90° as the firmware expects) and, with
--listen, prints any key/touchscreen events so you can confirm input works.
"""
import argparse
import os
import signal
import sys
import time

SDK_SRC = os.environ.get(
    "STREAMDOCK_SDK_SRC", os.path.join(os.path.dirname(__file__), "sdk", "src")
)
sys.path.insert(0, SDK_SRC)

from PIL import Image, ImageDraw, ImageFont                      # noqa: E402
from StreamDock import ProductIDs as PID_TABLE                  # noqa: E402
from StreamDock.Devices.StreamDock293s import StreamDock293s    # noqa: E402

VID, PID = 0x5548, 0x6674
PID_TABLE.g_products.append((VID, PID, StreamDock293s))          # the only patch

from StreamDock.DeviceManager import DeviceManager               # noqa: E402


def make_face(text, sub=None, size=85):
    img = Image.new("RGB", (size, size), (32, 32, 32))
    d = ImageDraw.Draw(img)
    for i in range(size):                                        # subtle gradient
        d.line([(0, i), (size, i)], fill=(28 + i // 6, 40 + i // 5, 56 + i // 4))
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
        small = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 11)
    except Exception:
        font = small = ImageFont.load_default()
    w = d.textlength(text, font=font)
    d.text(((size - w) / 2, 24), text, font=font, fill=(255, 255, 255))
    if sub:
        w2 = d.textlength(sub, font=small)
        d.text(((size - w2) / 2, 56), sub, font=small, fill=(180, 220, 240))
    d.rectangle([0, 0, size - 1, size - 1], outline=(61, 154, 209), width=1)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default="1,5", help="logical key numbers (1-15 icons, 16-18 second screen)")
    ap.add_argument("--listen", type=int, default=0, help="seconds to listen for key events")
    ap.add_argument("--clear", action="store_true", help="clear all icons instead of drawing")
    ap.add_argument("--no-init", dest="init", action="store_false",
                    help="skip init() (wake/brightness/clear/refresh); writes may be invisible")
    ap.set_defaults(init=True)
    args = ap.parse_args()

    mgr = DeviceManager()
    devs = mgr.enumerate()
    if not devs:
        print(f"no device found for {VID:#06x}:{PID:#06x}", file=sys.stderr)
        return 1
    dev = devs[0]
    print(f"found {type(dev).__name__} path={dev.path}")

    if not dev.open():
        print("open() failed", file=sys.stderr)
        return 1
    print(f"opened; firmware reported by the device: {getattr(dev, 'firmware_version', '?')}")

    # MUST come before the SDK's reader thread reads anything. set_device() is what sets
    # the HID report size (513/513 on this family); without it the transport reads into a
    # zero-length buffer and the C library aborts the process (SIGABRT in transport_read).
    # The SDK only calls this from init(), which also wipes every icon — so call it alone.
    dev.set_device()

    if args.init:
        # wake + brightness + clearAllIcon + refresh. Skipping this is why the first
        # attempts looked dead: the transport accepted every write (rc 0) but the panel
        # stayed asleep, so nothing appeared. Verified on hardware: with init() the faces
        # show; without it, silence.
        dev.init()
    else:
        dev.wakeScreen()
        dev.set_brightness(85)

    if args.clear:
        dev.clearAllIcon()
        print("cleared all icons")
    else:
        for k in (int(x) for x in args.keys.split(",") if x.strip()):
            img = make_face(f"K{k}", "no app")
            path = f"/tmp/sd_k{k}.jpg"
            img.save(path, "JPEG", quality=95)
            rc = dev.set_key_image(k, path)
            print(f"set_key_image(key={k}) -> {rc}")

    if args.listen:
        print(f"listening for input for {args.listen}s — press keys / touch the strip", flush=True)
        events = []

        # Do NOT rely on the SDK's key_callback for this unit. Its decoder
        # (StreamDock._is_input_event_packet) requires packets framed "ACK"/"OK":
        #     data[0..2] == 41 43 4B   data[5..6] == 4F 4B
        # This firmware sends a 512-byte report with the key code at byte 9 and the state at
        # byte 10, everything else zero — so every event fails that test and is dropped
        # silently. Decode the raw packet ourselves instead; raw_read_callback fires for
        # every packet, before the ACK filter.
        hw_to_logical = {v: k for k, v in StreamDock293s._IMAGE_KEY_MAP.items()}

        def on_event(device, event):
            events.append(event)
            print("  event:", event, flush=True)

        def on_raw(device, packet):
            b = bytes(packet)
            if len(b) < 11:
                return
            code, state = b[9], b[10]
            if code in (0x00, 0xFF):
                return
            logical = hw_to_logical.get(code)
            events.append((code, state, logical))
            print(f"  RX hw={code:2d} state=0x{state:02x} -> logical {logical}  [{b[:14].hex(' ')}]",
                  flush=True)

        dev.raw_read_callback = on_raw
        dev.key_callback = None
        dev.touchscreen_callback = None

        end = time.time() + args.listen
        while time.time() < end:
            time.sleep(0.1)
        print(f"captured {len(events)} events")

    dev.close()
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    sys.exit(main())
