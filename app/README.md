# Deckhand — a native macOS driver and UI for the AJAZZ Stream Dock 293S

Deckhand replaces the vendor application (~1.4 GB Electron/CEF) with a ~2.4 MB native SwiftUI app that
drives the panel over IOKit directly. No vendor binary is loaded, shipped or required — the HID protocol
was recovered by static analysis and verified against the hardware.

    app/                          the macOS app (SwiftPM, no Xcode project)
      Sources/Deckhand/
        NativeTransport.swift     IOKit driver: reports, commands, input, firmware
        Device.swift              key map, hot-plug, USB port summary
        Model.swift               Profile / Slot / KeyAction + on-disk store
        ImagePrep.swift           90° rotation, resize, JPEG
        Widgets.swift             1×3 window renderer (clock, date, CPU, memory, page, text)
        InspectorView.swift       key inspector
        UI.swift                  split view, key grid, sidebar
        Hotkey.swift              CGEvent emission + Accessibility handling
        ControlServer.swift       Unix control socket (NDJSON)
        Settings.swift            storage folders (default ~/Documents/Deckhand)
        L10n.swift                strings, follows the system language (en · zh-Hans · ms)
      build.sh                    assembles and signs Deckhand.app (arm64)
    Sources/StreamDockMCP/        stdio MCP server that drives the app over its socket
    docs/protocol-native.md       the recovered wire protocol, with sources
    device/, re/                  bring-up tooling and the vendor A/B reference harness

## Status — proven on hardware

| area | state |
|---|---|
| display: all 18 slots, images and window widgets | verified |
| physical key presses (15 keys, 350 ms debounce) | verified |
| bindings: open app, hotkey chord, URL, script, page next/prev/first | verified by pressing keys |
| two different apps launched from two keys | verified |
| pages (host-side; 4 is a product cap, not a firmware limit) | verified |
| brightness · wake · commit · heartbeat | implemented from the decompile, exercised indirectly |
| hot-plug (unplug → "Not connected", replug → reconnect) | verified |
| clearing a key then Send to Device blanks it on the panel | verified |

## Protocol

Full write-up in `docs/protocol-native.md`. Recovered from the vendor library's
`Transport::setKeyImgFileStream`, `setKeyBrightness`, `heartbeat`, `changePage` and
`TransportSession::transact`:

    reports     512-byte output reports, report ID 0x00
    image       report 1: 13-byte header "CRT\0\0BAT" + BE32(len) + key, zero padded to 512
                report 2+: the JPEG, 512 bytes per report
    commit      "CRT\0\0STP"       wake:   "CRT\0\0DIS"      keep-alive: "CRT\0\0CONNECT"
    page        "M_V" + page       brightness: "CRT\0\0LIG" + 0x00 0x00 + percent
    input       512-byte report, byte[9] = hardware key code, no release event (debounce)

Three details cost most of the debugging, documented so nobody repeats it:

* **the header is its own report** — concatenating header + JPEG into one stream returns success for
  every write and renders nothing at all;
* **JPEG chunks are 512 bytes** — 511 shifts every chunk after the first and the panel paints noise;
* **the panel does not ack image reports** — the vendor's own read times out, so a per-report ack wait
  only adds latency (300 ms × ~36 reports froze the UI for 40 s).

The key numbering is by hardware code, not visual order: `1→13, 2→10, 3→7, 4→4, 5→1, 6→14, …, 15→3`,
with 16–18 the display-only window. `Device.logicalToHardware` holds the table for writes,
`hardwareToLogical` for input.

## Build

    cd app && ./build.sh          # → Deckhand.app (arm64)
    open Deckhand.app

macOS 14+, Xcode command line tools. The app seizes the HID device while running, so other tools go
through its control socket (`~/Library/Application Support/Deckhand/control.sock`) or the MCP server.

    printf '{"cmd":"status"}\n' | nc -U ~/Library/Application\ Support/Deckhand/control.sock
    {"ok":true,"connected":true,"firmware":"V2.293.00.001","profile":"Demo","live":"Demo",...}

## Features

* **Fast sync**: a push renders each slot, hashes the bytes and writes only what changed — a no-op
  Send to Device is ~60 ms instead of ~600 ms. The write loop runs on its own queue, so a slow
  transfer cannot stall the window. The cache resets on page change, profile switch and re-plug.
* **Profiles** in the sidebar, each with up to 4 host-side pages and 18 slots per page.
  Selecting a profile only *edits* it; **Send to Device** (⇧⌘R) is what puts it on the panel — the
  sidebar marks the live profile "On device".
* **Graphics per key**: choose a file or drop one on the tile, then either adjust it (rotate, zoom,
  crop, arrow-pad) or use the original untouched. Images are written to the key immediately.
* **Bindings**: key combination (recorded), open app, open URL, run script (picks a `.sh`/`.scpt`/
  executable), and page navigation (next / previous / first) as first-class actions.
* **The 1×3 window** is host-rendered: clock, date, CPU, memory, page number or custom text, drawn per
  pane and pushed when the picture changes.
* **Runs in the menu bar**: closing the window hides it instead of quitting, so the panel keeps working
  with no window open. The status item shows connection state and offers Open / Send to Device / Next–
  Previous page / Quit. Settings has "Keep running in the menu bar" (on by default) and "Open Deckhand
  at login" (SMAppService).
* **Settings (⌘,)** choose where profiles and graphics live, defaulting to `~/Documents/Deckhand`.
* **Localisation** follows the system language — English, Simplified Chinese, Bahasa Melayu.

## Licence

MIT for this code. The vendor's SDK (`device/sdk/`, `TransportDLL/libtransport.dylib`) is **not** part of
the release — it was used as a reference oracle during development and is excluded by `.gitignore`. The
protocol was reimplemented from observation and static analysis; no vendor code is linked or copied.
