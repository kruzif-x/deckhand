#!/usr/bin/env python3
"""
sdk_raw_read.py — does the vendor SDK's transport deliver input reports at all on macOS?

Bypasses the SDK's reader thread and its ACK/OK packet filter entirely: open the device the
same way drive_test.py does, then call transport.read_() in a tight loop and print anything
non-empty. The Swift probe (hidprobe) reading the same device at the same time is the control.

    ./.venv/bin/python sdk_raw_read.py 30
"""
import sys
import time

sys.path.insert(0, "sdk/src")
from StreamDock import ProductIDs as P                       # noqa: E402
from StreamDock.Devices.StreamDock293s import StreamDock293s  # noqa: E402

P.g_products.append((0x5548, 0x6674, StreamDock293s))

from StreamDock.DeviceManager import DeviceManager            # noqa: E402

seconds = float(sys.argv[1]) if len(sys.argv) > 1 else 30.0

d = DeviceManager().enumerate()[0]
print("open:", d.open(), flush=True)
d.set_device()                      # report sizes; without it the transport aborts
d.set_brightness(80)

n = 0
end = time.time() + seconds
while time.time() < end:
    try:
        pkt = d.transport.read_(513)
    except Exception as e:
        print("read raised:", e, flush=True)
        break
    if pkt:
        n += 1
        print(f"  transport.read_ -> {len(pkt)} bytes: {bytes(pkt)[:16].hex(' ')}", flush=True)
print(f"non-empty reads: {n}", flush=True)
d.close()
