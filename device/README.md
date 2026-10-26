# Read-only probe of the Stream Dock (VID 0x5548 / PID 0x6674)

> **Historical tooling.** These scripts were used to bring up the unit and to prove the protocol.
> `deck.py` and `drive_test.py` import the vendor's Python SDK, which has been **deleted** from this
> repository (it is not redistributable), so they only run if you supply that SDK yourself.
> Everything they were used to discover is implemented in `app/Sources/Deckhand/NativeTransport.swift`
> and documented in `docs/protocol-native.md`; `hidprobe.swift`, `hidreader.swift`, `hidraw.swift` and
> the shell wrappers are stand-alone IOKit code and still build and run.

`hidprobe.swift` opens the device through `IOHIDManager`, dumps every property macOS
exposes, reads the vendor feature report, and listens for unsolicited input reports.
It never writes an output or feature report — nothing on the device changes.

    swiftc -O -framework IOKit -framework CoreFoundation hidprobe.swift -o hidprobe
    ./hidprobe 6

## What the probe returned (2026-10-25, probe-output.txt)

    VendorID / ProductID      21832 (0x5548) / 26228 (0x6674)
    VersionNumber             768  (bcdDevice 0x0300)
    Transport                 USB, full speed, LocationID 0x2100000
    PrimaryUsagePage/Usage   65440 (0xFFA0) / 1
    Max input / output        512 / 512 bytes, interval 125 Hz
    Max feature report        0  (per the descriptor … )

    reportDescriptor          06 a0 ff 09 01 a1 01 09 02 a1 00 06 a1 ff 09 03 09 04
                              15 80 25 7f 35 00 45 ff 75 08 96 00 02 81 02
                              09 05 09 06 15 80 25 7f 35 00 45 ff 75 08 96 00 02
                              91 02 c0 c0

    featureReport(0..7)       ok, 13 bytes: "V2.293.00.001"   (same for every report id)
    input reports in 6 s      0

## What that means

1. **No human-interface usages at all.** The descriptor declares two vendor pages
   (0xFFA0, 0xFFA1) with one 512-byte input and one 512-byte output report. There is no
   Generic Desktop, Keyboard, Mouse or Consumer collection, so macOS never gives the
   device any input capability. It cannot type, click or send media keys — the usual
   "BadUSB" concern does not apply to this hardware.

2. **The device is quiet unless polled.** Zero unsolicited input reports in six seconds
   (and in every repeat run). It is a request/response HID pipe driven by the host app,
   not something that can push keystrokes on its own.

3. **It exposes a firmware string the USB descriptors do not.** `V2.293.00.001` comes back
   from a plain `IOHIDDeviceGetReport(kIOHIDReportTypeFeature, …)` GET, for every report
   id tried. This is how the vendor app tells devices apart: the `293` matches the
   "Stream Dock 293S" family in the app's own device table (`Stream Dock 293S`, `293SV3`,
   `VSD 293SV3`, `APK153_293SV3`, …), whose public PID is 0x6670 — this unit is 0x6674, a
   newer revision of the same family.

4. **No permission prompt.** Reading the feature report and opening the device needed no
   Input Monitoring / Accessibility grant, because the usage page is vendor-defined rather
   than keyboard. The flip side: any local process can read that string, and can also open
   the vendor pipe and push output reports (images, LED state) to the panel. The device
   has no notion of which process is talking to it — that is inherent to HID, and the
   reason the vendor app's own protocol hardening matters.

5. **No firmware offered for this PID.** Both vendor firmware manifests were checked:
   `firmware-version-check.json` carries only `MBox-N1 → V3.N1.01.001`, and
   `firmware-version-mirabox.json` keys models by name and by `VID&PID`
   (`21832&4113`, `21832&4119`, `21832&4137`, …). None of them is PID 26228. So on this
   unit the app has nothing to flash — which removes the unsigned-firmware risk for this
   particular device, but only because of a manifest gap, not because of a signature check.

## What actually works, in one table

| capability | path | status |
|---|---|---|
| identify model / firmware | HID feature GET, and the SDK's own query | `V2.293.00.001`, 293S, PID 0x6674 |
| draw a key (85/96/100 px) | vendor SDK + one-line PID patch | verified on hardware |
| text, gradients, colour emoji | `deck.py demo` / `text` / `emoji` | verified on hardware, all 18 slots (`preview-emoji-sheet.png`) |
| wake / brightness / refresh | SDK `init()` | required; without it writes are invisible |
| read key presses | IOHIDManager (`hidreader`, JSON lines) | **verified end to end**: 15 presses → 15 JSON lines with the correct logical keys |
| read key presses via the SDK | `key_callback` | **broken** — ACK/OK packet filter |
| 3-slot secondary strip | image yes, input no | display only |

Logs of every experiment are under `logs/` (`run_A` = the SIGABRT, `run_B`/`run_C` = the fix,
`probe-output.txt` = feature-report + input capture).

## Colour emoji on the keys

`deck.py emoji` renders Apple Color Emoji and writes one per slot:

    keys 1-15     😀 😎 🤖 🎵 🔥 ⭐ ❤️ 👍 🎉 🚀 🌈 🍕 ☕ 📷 🎮
    window 16-18  🕐 🔋 📶

Two constraints worth knowing, because both fail silently-ish:

* **Apple Color Emoji is a bitmap font with a single 160 px strike.** Load it at 160
  (`ImageFont.truetype("/System/Library/Fonts/Apple Color Emoji.ttc", 160)`) and draw with
  `embedded_color=True`, then crop to `getbbox()` and downscale. Other point sizes do not
  render the colour glyphs.
* Draw into an RGBA image and paste with the alpha channel, otherwise the glyph gets a black
  square behind it.

`preview-emoji-sheet.png` is the exact 18-tile sheet that was sent to the panel.

## Driving it without the vendor app

`drive_test.py` uses the vendor's own open-source Python SDK
(github.com/MiraboxSpace/StreamDock-Device-SDK, MIT, vendored under `sdk/`) and teaches it
this unit's PID. The whole patch is one line:

```python
PID_TABLE.g_products.append((0x5548, 0x6674, StreamDock293s))
```

The SDK's table maps 0x5548:0x6670 to `StreamDock293s`; this unit enumerates as 0x6674, so
without that line it is invisible to the SDK.

    ./build.sh                       # builds hidprobe + hidreader (Swift, no deps)
    ./deck.py info                   # device, firmware, mapping
    ./deck.py text 1 "HELLO"         # draw a generated face
    ./deck.py key 3 photo.png        # draw a file
    ./deck.py clear                  # blank every key
    ./deck.py listen                 # stream presses: {"hw":13,"state":0,"logical":1}
    ./.venv/bin/python drive_test.py --keys 1,5 --listen 60   # the raw experiment harness

Real output from this unit:

    found StreamDock293s path=DevSrvsID:4295109534
    opened; firmware reported by the device: V2.293.00.001
    set_key_image(key=1) -> 0
    set_key_image(key=5) -> 0

**The SDK's input path is broken on this unit — use `hidreader` / `deck.py listen`.** Two
separate defects, both confirmed on hardware:

1. *Packets are filtered out.* `StreamDock._is_input_event_packet()` only accepts frames
   shaped `41 43 4B … 4F 4B` ("ACK" at bytes 0-2, "OK" at 5-6). This firmware sends a
   512-byte report that is all zeros except byte 9 (key code) and byte 10 (state), so every
   press is discarded before decoding. `key_callback` therefore never fires — the display
   works, the buttons look dead.
2. *Silent when it does read.* Two 60 s listens with `key_callback` produced 0 events while
   an independent IOHID reader captured `hw=13` (key 1) and `hw=5` (key 9) in the same
   session. Whether the macOS transport delivers reports to hidapi at all was not isolated;
   it does not matter operationally, because input is read from IOHID instead.

So `deck.py` splits the work: **images via the vendor SDK, input via `hidreader`** (Swift +
IOHIDManager, one JSON line per event).

### Geometry (confirmed by the owner of the unit)

    15 pressable buttons   arranged 5 columns x 3 rows
                           logical 1-5 = top row left→right, 6-10 middle, 11-15 bottom
     1 x 3 display window  three slots, images only, no input at all (logical 16-18)
    ---------------------
    18 image slots total   which is exactly why the 293s class has KEY_COUNT = 18

Hardware code → logical key, **verified by pressing all 15 buttons once each** (15 events,
15 distinct codes, no gaps, no duplicates):

| row | logical keys | hardware codes |
|---|---|---|
| top    | 1  2  3  4  5  | 13 10  7  4  1 |
| middle | 6  7  8  9 10  | 14 11  8  5  2 |
| bottom | 11 12 13 14 15 | 15 12  9  6  3 |
| window | 16 17 18       | 16 17 18 (images only) |

Two properties of the input stream worth knowing before writing a consumer:

* **One report per press**, 512 bytes, key code at byte 9, `state` always `0x00`.
* **No release events.** This firmware does not send a separate key-up, so every event is a
  press; do not wait for a matching release or the UI will stick.

`deck.py identify` walks every slot in order (0.8 s each by default) so the arrangement can be
read straight off the hardware, and leaves all 18 labelled.

**A crash you will hit if you skip `init()`.** The SDK's `init()` is what calls
`set_device()`, which sets the HID report size to 513/513. Open the device and skip `init()`
(which is tempting, because it also wipes every icon) and the reader thread calls
`transport_read` with a zero-length buffer — the C transport aborts the process:

    Fatal Python error: Aborted
      File "StreamDock/Transport/LibUSBHIDAPI.py", line 1300 in read_
      File "StreamDock/Devices/StreamDock.py", line 503 in _read
    Abort trap: 6        (exit 134)

`drive_test.py` therefore calls `dev.set_device()` explicitly right after `open()`, and
verified with a 12 s idle run and a set-then-listen run (`run_B.txt`, `run_C.txt`). Call
`init()` instead if you actually want the SDK's full reset behaviour.

Notes:

* `V2.293.00.001` is the device answering the SDK's own firmware query — an independent
  confirmation of the string the feature-report probe returned.
* Return code `0` means the transport wrote every JPEG chunk. Visual confirmation is on
  the hardware; `--listen` covers the input side (key presses, touch strip).
* Key faces are 85x85 JPEG rotated 90°, which is what the 293s firmware expects. Keys
  1-15 are the icon keys, 16-18 the secondary screen strip.
* The SDK's `init()` clears all icons and sets brightness/state; `drive_test.py`
  deliberately skips it and only wakes the screen, sets brightness and writes the keys it
  was asked for.
* Everything runs as the logged-in user over HID. No launch agent, no privileges, no
  network, no vendor app.

## Limitations

* Report/feature reads only. The vendor protocol's own "get version/model" command (an
  output report written by the host) was deliberately not sent.
* The 293S PID block is inferred from the firmware string plus the vendor's device table;
  the public SDK lists 0x6670 for 293S and does not list 0x6674 at all.
* One machine, one unit, one firmware version.
